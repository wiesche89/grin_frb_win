use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use bitcoin::secp256k1::{rand::rngs::OsRng, All, Secp256k1};
use grin_util::secp::{ContextFlag, Secp256k1 as GrinSecp256k1};
use once_cell::sync::Lazy;
use serde::Serialize;
use std::sync::{Arc, Mutex};

use mw_atomic_swap::{
    commands::cmd_types::cancel::Cancel,
    commands::cmd_types::command::Command,
    commands::cmd_types::execute::Execute,
    commands::cmd_types::init::Init,
    commands::cmd_types::lock::Lock,
    enums::Currency,
    settings::Settings,
    swap::slate::{
        create_priv_from_pub, get_slate_checksum, read_slate_from_disk, write_slate_to_disk,
    },
    swap::swap_types::{SwapSlate, SwapSlatePub},
};

const SETTINGS_FILE: &str = "config/settings.json";

struct AtomicSwapRuntime {
    settings: Settings,
    btc_secp: Secp256k1<All>,
    grin_secp: GrinSecp256k1,
}

static RUNTIME: Lazy<Mutex<Option<Arc<AtomicSwapRuntime>>>> = Lazy::new(|| Mutex::new(None));
static SLATE_OVERRIDE: Lazy<Mutex<Option<PathBuf>>> = Lazy::new(|| Mutex::new(None));
static PEER_OVERRIDE: Lazy<Mutex<Option<(String, String)>>> = Lazy::new(|| Mutex::new(None));

fn initialize_runtime() -> Result<AtomicSwapRuntime> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let swap_dir = manifest_dir.join("mw_atomic_swap");
    let config_path = swap_dir.join(SETTINGS_FILE);

    let raw = fs::read_to_string(&config_path).with_context(|| {
        format!(
            "Failed to read atomic swap config at {}",
            config_path.display()
        )
    })?;

    let mut settings: Settings =
        serde_json::from_str(&raw).context("Failed to parse atomic swap settings")?;

    let (south_addr, south_port) = resolve_peer_endpoint(&settings)?;
    settings.tcp_addr = south_addr;
    settings.tcp_port = south_port;
    let slate_dir = resolve_slate_directory(&swap_dir, &settings)?;
    fs::create_dir_all(&slate_dir)
        .with_context(|| format!("Cannot create slate directory {}", slate_dir.display()))?;
    settings.slate_directory = slate_dir.to_string_lossy().to_string();

    Ok(AtomicSwapRuntime {
        settings,
        btc_secp: Secp256k1::new(),
        grin_secp: GrinSecp256k1::with_caps(ContextFlag::Commit),
    })
}

fn runtime() -> Result<Arc<AtomicSwapRuntime>> {
    let mut guard = RUNTIME
        .lock()
        .map_err(|e| anyhow!("Runtime mutex poisoned: {e}"))?;
    if let Some(existing) = guard.clone() {
        return Ok(existing);
    }
    let runtime = Arc::new(initialize_runtime()?);
    *guard = Some(runtime.clone());
    Ok(runtime)
}

fn parse_currency(value: &str) -> Result<Currency> {
    match value.trim().to_uppercase().as_str() {
        "BTC" | "BITCOIN" => Ok(Currency::BTC),
        "GRIN" => Ok(Currency::GRIN),
        other => Err(anyhow!("Unsupported currency: {}", other)),
    }
}

fn resolve_slate_directory(swap_dir: &Path, settings: &Settings) -> Result<PathBuf> {
    if let Some(override_) = SLATE_OVERRIDE
        .lock()
        .map_err(|e| anyhow!("Override lock failed: {e}"))?
        .clone()
    {
        return Ok(override_);
    }
    if let Ok(env_dir) = env::var("GRIN_FRB_SWAP_DIRECTORY") {
        return Ok(PathBuf::from(env_dir));
    }
    if let Ok(node_wallet_dir) = env::var("FRB_WALLET_DATA") {
        let path = PathBuf::from(node_wallet_dir).join("atomic_swap_txs");
        return Ok(path);
    }
    let configured = PathBuf::from(&settings.slate_directory);
    if configured.is_absolute() {
        Ok(configured)
    } else {
        Ok(swap_dir.join(configured))
    }
}

fn resolve_peer_endpoint(settings: &Settings) -> Result<(String, String)> {
    if let Some((host, port)) = PEER_OVERRIDE
        .lock()
        .map_err(|e| anyhow!("Peer lock failed: {e}"))?
        .clone()
    {
        return Ok((host, port));
    }
    Ok((settings.tcp_addr.clone(), settings.tcp_port.clone()))
}

#[derive(Serialize)]
struct AtomicSwapRecord {
    id: u64,
    pub_slate: SwapSlatePub,
    checksum: Option<String>,
}

impl AtomicSwapRecord {
    fn from_slate(slate: SwapSlate, slate_dir: &str) -> Self {
        let checksum = get_slate_checksum(slate.id, slate_dir).ok();
        AtomicSwapRecord {
            id: slate.id,
            pub_slate: slate.pub_slate,
            checksum,
        }
    }

    fn from_pub(id: u64, pub_slate: SwapSlatePub, slate_dir: &str) -> Self {
        let checksum = get_slate_checksum(id, slate_dir).ok();
        AtomicSwapRecord {
            id,
            pub_slate,
            checksum,
        }
    }
}

pub fn init_swap(
    from_currency: &str,
    to_currency: &str,
    from_amount: u64,
    to_amount: u64,
    timeout_minutes: u64,
) -> Result<String> {
    let rt = runtime()?;
    let from = parse_currency(from_currency)?;
    let to = parse_currency(to_currency)?;
    let command = Init::new(from, to, from_amount, to_amount, timeout_minutes);
    let mut rng = OsRng::new().map_err(|e| anyhow!(e))?;
    let slate = command
        .execute(&rt.settings, &mut rng, &rt.btc_secp, &rt.grin_secp)
        .map_err(|e: String| anyhow!(e))?;

    write_slate_to_disk(&slate, &rt.settings.slate_directory, true, true);
    serde_json::to_string(&AtomicSwapRecord::from_slate(
        slate,
        &rt.settings.slate_directory,
    ))
    .context("Failed to serialize atomic swap record")
}

pub fn accept_swap(swap_id: u64) -> Result<String> {
    let rt = runtime()?;
    let slate =
        create_priv_from_pub(swap_id, &rt.settings.slate_directory).map_err(|e| anyhow!(e))?;
    serde_json::to_string(&AtomicSwapRecord::from_slate(
        slate,
        &rt.settings.slate_directory,
    ))
    .context("Failed to serialize atomic swap acceptance result")
}

pub fn read_swap(swap_id: u64) -> Result<String> {
    let rt = runtime()?;
    let slate =
        read_slate_from_disk(swap_id, &rt.settings.slate_directory).map_err(|e| anyhow!(e))?;
    serde_json::to_string(&AtomicSwapRecord::from_slate(
        slate,
        &rt.settings.slate_directory,
    ))
    .context("Failed to serialize atomic swap detail")
}

pub fn list_swaps() -> Result<String> {
    let rt = runtime()?;
    let dir = Path::new(&rt.settings.slate_directory);
    let mut records = Vec::new();

    for entry in fs::read_dir(dir).context("Failed to read slate directory")? {
        let entry = entry?;
        let file_name = entry.file_name();
        let name = match file_name.to_str() {
            Some(value) => value,
            None => continue,
        };

        if let Some(base) = name.strip_suffix(".pub.json") {
            if let Ok(id) = base.parse::<u64>() {
                let contents = fs::read_to_string(entry.path()).ok();
                if let Some(contents) = contents {
                    if let Ok(pub_slate) = serde_json::from_str::<SwapSlatePub>(&contents) {
                        records.push(AtomicSwapRecord::from_pub(
                            id,
                            pub_slate,
                            &rt.settings.slate_directory,
                        ));
                    }
                }
            }
        }
    }

    serde_json::to_string(&records).context("Failed to serialize atomic swap list")
}

pub fn swap_checksum(swap_id: u64) -> Result<String> {
    let rt = runtime()?;
    get_slate_checksum(swap_id, &rt.settings.slate_directory)
        .map_err(|e| anyhow!(e))
        .context("Failed to compute slate checksum")
}

pub fn set_slate_directory(path: &str) -> Result<()> {
    let mut override_guard = SLATE_OVERRIDE
        .lock()
        .map_err(|e| anyhow!("Override lock failed: {e}"))?;
    *override_guard = Some(PathBuf::from(path));

    let mut runtime_guard = RUNTIME
        .lock()
        .map_err(|e| anyhow!("Runtime lock failed: {e}"))?;
    *runtime_guard = None;
    Ok(())
}

pub fn set_peer_endpoint(host: &str, port: &str) -> Result<()> {
    let mut peer_guard = PEER_OVERRIDE
        .lock()
        .map_err(|e| anyhow!("Peer override lock failed: {e}"))?;
    *peer_guard = Some((host.to_string(), port.to_string()));

    let mut runtime_guard = RUNTIME
        .lock()
        .map_err(|e| anyhow!("Runtime lock failed: {e}"))?;
    *runtime_guard = None;
    Ok(())
}

pub fn lock_swap(swap_id: u64) -> Result<String> {
    let rt = runtime()?;
    let mut rng = OsRng::new().map_err(|e| anyhow!(e))?;
    let locker = Lock::new(swap_id);
    let slate = locker
        .execute(&rt.settings, &mut rng, &rt.btc_secp, &rt.grin_secp)
        .map_err(|e: String| anyhow!(e))?;
    write_slate_to_disk(&slate, &rt.settings.slate_directory, true, true);
    serde_json::to_string(&AtomicSwapRecord::from_slate(
        slate,
        &rt.settings.slate_directory,
    ))
    .context("Failed to serialize atomic swap lock response")
}

pub fn execute_swap(swap_id: u64) -> Result<String> {
    let rt = runtime()?;
    let mut rng = OsRng::new().map_err(|e| anyhow!(e))?;
    let executor = Execute::new(swap_id);
    let slate = executor
        .execute(&rt.settings, &mut rng, &rt.btc_secp, &rt.grin_secp)
        .map_err(|e: String| anyhow!(e))?;
    write_slate_to_disk(&slate, &rt.settings.slate_directory, true, true);
    serde_json::to_string(&AtomicSwapRecord::from_slate(
        slate,
        &rt.settings.slate_directory,
    ))
    .context("Failed to serialize atomic swap execute response")
}

pub fn cancel_swap(swap_id: u64) -> Result<String> {
    let rt = runtime()?;
    let mut rng = OsRng::new().map_err(|e| anyhow!(e))?;
    let canceller = Cancel::new(swap_id);
    let slate = canceller
        .execute(&rt.settings, &mut rng, &rt.btc_secp, &rt.grin_secp)
        .map_err(|e: String| anyhow!(e))?;
    write_slate_to_disk(&slate, &rt.settings.slate_directory, true, true);
    serde_json::to_string(&AtomicSwapRecord::from_slate(
        slate,
        &rt.settings.slate_directory,
    ))
    .context("Failed to serialize atomic swap cancel response")
}

pub fn delete_swap(swap_id: u64) -> Result<String> {
    let rt = runtime()?;
    let dir = Path::new(&rt.settings.slate_directory);
    let pub_path = dir.join(format!("{swap_id}.pub.json"));
    let prv_path = dir.join(format!("{swap_id}.prv.json"));
    let mut removed = Vec::new();
    if pub_path.exists() {
        fs::remove_file(&pub_path)
            .with_context(|| format!("Failed to remove {}", pub_path.display()))?;
        removed.push(pub_path);
    }
    if prv_path.exists() {
        fs::remove_file(&prv_path)
            .with_context(|| format!("Failed to remove {}", prv_path.display()))?;
        removed.push(prv_path);
    }
    if removed.is_empty() {
        Err(anyhow!("No slate files found for swap {}", swap_id))
    } else {
        Ok(format!("Removed {} file(s) for swap {}", removed.len(), swap_id))
    }
}

pub fn import_public_slate(swap_id: u64, payload: &str) -> Result<String> {
    let rt = runtime()?;
    let _pub_slate: SwapSlatePub =
        serde_json::from_str(payload).context("Payload is not valid SwapSlatePub JSON")?;
    let dir = Path::new(&rt.settings.slate_directory);
    fs::create_dir_all(dir)
        .with_context(|| format!("Cannot create slate directory {}", dir.display()))?;
    let dest = dir.join(format!("{swap_id}.pub.json"));
    fs::write(&dest, payload)
        .with_context(|| format!("Failed to write slate file {}", dest.display()))?;
    Ok(payload.to_string())
}
