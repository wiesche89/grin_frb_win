use std::collections::HashMap;
use std::convert::TryFrom;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, Once};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};
use grin_core::global::{self, ChainTypes};
use grin_keychain::ExtKeychain;
use grin_util::secp::key::SecretKey;
use grin_util::{Mutex as GrinMutex, ToHex, ZeroingString};
use grin_wallet_api::{Foreign, Owner};
use grin_wallet_config::{WalletConfig, WALLET_CONFIG_FILE_NAME};
use grin_wallet_controller::command::{self, CancelArgs, CheckArgs, RepostArgs};
use grin_wallet_impls::{DefaultLCProvider, DefaultWalletImpl, HTTPNodeClient};
use grin_wallet_libwallet::{
    self,
    api_impl::types::IssueInvoiceTxArgs,
    InitTxArgs,
    OutputCommitMapping,
    PaymentProof,
    SlatepackAddress,
    SlateState,
    TxLogEntry,
    TxLogEntryType,
    WalletInfo,
    WalletInst,
};
use once_cell::sync::Lazy;
use serde::Serialize;
use serde_json;

type WalletBackendInstance = Arc<
    GrinMutex<
        Box<
            dyn WalletInst<
                'static,
                DefaultLCProvider<'static, HTTPNodeClient, ExtKeychain>,
                HTTPNodeClient,
                ExtKeychain,
            >,
        >,
    >,
>;

type OwnerApi = Owner<
    DefaultLCProvider<'static, HTTPNodeClient, ExtKeychain>,
    HTTPNodeClient,
    ExtKeychain,
>;

struct WalletRuntime {
    owner: OwnerApi,
    keychain_mask: Option<SecretKey>,
    _data_dir: PathBuf,
    _node_url: String,
    active_account: String,
}

static WALLET_RUNTIME: Lazy<Mutex<Option<WalletRuntime>>> = Lazy::new(|| Mutex::new(None));
static CHAIN_INIT: Once = Once::new();
static NODE_URL: Lazy<Mutex<String>> =
    Lazy::new(|| Mutex::new("https://grincoin.org".to_string()));

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WalletInfoDto {
    refreshed_from_node: bool,
    info: WalletInfo,
    active_account: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TransactionDto {
    id: u32,
    tx_slate_id: Option<String>,
    tx_type: String,
    status: String,
    direction: String,
    creation_ts: String,
    confirmation_ts: Option<String>,
    confirmed: bool,
    amount: u64,
    fee: Option<u64>,
    num_inputs: usize,
    num_outputs: usize,
    has_proof: bool,
    kernel_excess: Option<String>,
    ttl_cutoff_height: Option<u64>,
    reverted_after_secs: Option<u64>,
    confirmations: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OutputDto {
    commitment: String,
    value: u64,
    status: String,
    height: u64,
    lock_height: u64,
    is_coinbase: bool,
    mmr_index: Option<u64>,
    tx_log_id: Option<u32>,
    confirmations: u64,
    spendable: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AccountDto {
    label: String,
    path: String,
    is_active: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ScanResultDto {
    delete_unconfirmed: bool,
    start_height: Option<u64>,
    backwards_from_tip: Option<u64>,
    performed_at_epoch_secs: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PaymentProofDto {
    tx_id: u32,
    proof: PaymentProof,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PaymentProofVerificationDto {
    is_sender: bool,
    is_recipient: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SlateInspectionDto {
    code: String,
    slate_id: String,
    state: String,
    amount: u64,
    fee: u64,
    num_participants: u16,
    kernel_excess: Option<String>,
}

impl TransactionDto {
    fn from_entry(entry: TxLogEntry, confirmations: u64) -> Self {
        let direction = tx_direction(&entry.tx_type).to_string();
        let status = tx_status(&entry).to_string();
        let amount = match direction.as_str() {
            "sent" => entry
                .amount_debited
                .saturating_sub(entry.amount_credited)
                .max(0),
            _ => entry
                .amount_credited
                .saturating_sub(entry.amount_debited)
                .max(0),
        };
        TransactionDto {
            id: entry.id,
            tx_slate_id: entry.tx_slate_id.map(|id| id.to_string()),
            tx_type: format!("{:?}", entry.tx_type),
            status,
            direction,
            creation_ts: entry.creation_ts.to_rfc3339(),
            confirmation_ts: entry.confirmation_ts.map(|ts| ts.to_rfc3339()),
            confirmed: entry.confirmed,
            amount,
            fee: entry.fee.as_ref().map(|f| f.fee()),
            num_inputs: entry.num_inputs,
            num_outputs: entry.num_outputs,
            has_proof: entry.payment_proof.is_some(),
            kernel_excess: entry.kernel_excess.as_ref().map(|c| c.to_hex()),
            ttl_cutoff_height: entry.ttl_cutoff_height,
            reverted_after_secs: entry.reverted_after.map(|d| d.as_secs()),
            confirmations,
        }
    }
}

impl OutputDto {
    fn from_mapping(mapping: OutputCommitMapping, current_height: u64) -> Self {
        let output = mapping.output;
        let confirmations = output.num_confirmations(current_height);
        let spendable = output.eligible_to_spend(current_height, 10);
        OutputDto {
            commitment: mapping.commit.to_hex(),
            value: output.value,
            status: format!("{:?}", output.status),
            height: output.height,
            lock_height: output.lock_height,
            is_coinbase: output.is_coinbase,
            mmr_index: output.mmr_index,
            tx_log_id: output.tx_log_entry,
            confirmations,
            spendable,
        }
    }
}

pub fn reset() {
    if let Ok(mut guard) = WALLET_RUNTIME.lock() {
        *guard = None;
    }
}

pub fn update_node_url(url: &str) -> Result<()> {
    let cleaned = url.trim();
    if cleaned.is_empty() {
        return Err(anyhow!("Node-URL darf nicht leer sein"));
    }
    if !(cleaned.starts_with("http://") || cleaned.starts_with("https://")) {
        return Err(anyhow!("Node-URL muss mit http:// oder https:// beginnen"));
    }
    let mut guard = NODE_URL
        .lock()
        .map_err(|_| anyhow!("Node-URL konnte nicht gesetzt werden"))?;
    if *guard != cleaned {
        *guard = cleaned.to_string();
        reset();
    }
    Ok(())
}

pub fn current_node_url() -> Result<String> {
    NODE_URL
        .lock()
        .map_err(|_| anyhow!("Node-URL konnte nicht gelesen werden"))
        .map(|s| s.clone())
}

pub fn node_tip() -> Result<u64> {
    ensure_chain_type();
    let url = current_node_url()?;
    let client = HTTPNodeClient::new(&url, None)
        .map_err(|e| anyhow!("NodeClient konnte nicht erstellt werden: {e}"))?;
    let (height, _) = client
        .chain_height()
        .map_err(|e| anyhow!("Node Tip Fehler: {e}"))?;
    Ok(height)
}

pub fn init_or_open(data_dir: &str, passphrase: &str) -> Result<()> {
    ensure_chain_type();
    let resolved = resolve_data_dir(data_dir)?;
    let node_url = current_node_url()?;
    let runtime = build_runtime(&resolved, passphrase, &node_url)?;
    let mut guard = WALLET_RUNTIME
        .lock()
        .map_err(|_| anyhow!("Wallet-Lock konnte nicht bezogen werden"))?;
    *guard = Some(runtime);
    Ok(())
}

pub fn create_wallet(data_dir: &str, passphrase: &str, mnemonic_length: usize) -> Result<String> {
    ensure_chain_type();
    let resolved = resolve_data_dir(data_dir)?;
    let node_url = current_node_url()?;
    let mut wallet = build_wallet_backend(&resolved, &node_url)?;
    let mut wallet_config = WalletConfig::default();
    wallet_config.chain_type = Some(ChainTypes::Mainnet);
    wallet_config.check_node_api_http_addr = node_url.clone();
    wallet_config.data_file_dir = resolved.to_string_lossy().to_string();

    {
        let lc = wallet.lc_provider().map_err(|e| anyhow!("LC-Provider fehlgeschlagen: {e}"))?;
        lc.set_top_level_directory(&wallet_config.data_file_dir)
            .map_err(|e| anyhow!("Top-Level-Verzeichnis konnte nicht gesetzt werden: {e}"))?;
        lc.create_config(
            &ChainTypes::Mainnet,
            WALLET_CONFIG_FILE_NAME,
            Some(wallet_config.clone()),
            None,
            None,
        )
        .map_err(|e| anyhow!("Wallet-Konfiguration konnte nicht erstellt werden: {e}"))?;
        lc.create_wallet(
            None,
            None,
            mnemonic_length,
            ZeroingString::from(passphrase),
            false,
        )
        .map_err(|e| anyhow!("Wallet konnte nicht erstellt werden: {e}"))?;
        let phrase = lc
            .get_mnemonic(None, ZeroingString::from(passphrase))
            .map_err(|e| anyhow!("Seedphrase konnte nicht gelesen werden: {e}"))?;
        // Wallet ist jetzt erstellt, Runtime aufbauen
        let runtime = build_runtime(&resolved, passphrase, &node_url)?;
        let mut guard = WALLET_RUNTIME
            .lock()
            .map_err(|_| anyhow!("Wallet-Lock konnte nicht bezogen werden"))?;
        *guard = Some(runtime);
        return Ok(phrase.to_string());
    }
}

pub fn seed_phrase(data_dir: &str, passphrase: &str) -> Result<String> {
    let resolved = resolve_data_dir(data_dir)?;
    let node_url = current_node_url()?;
    let mut wallet = build_wallet_backend(&resolved, &node_url)?;
    let lc = wallet.lc_provider().map_err(|e| anyhow!("LC-Provider fehlgeschlagen: {e}"))?;
    let dir_string = resolved.to_string_lossy().to_string();
    lc.set_top_level_directory(&dir_string)
        .map_err(|e| anyhow!("Top-Level-Verzeichnis konnte nicht gesetzt werden: {e}"))?;
    let mnemonic = lc
        .get_mnemonic(None, ZeroingString::from(passphrase))
        .map_err(|e| anyhow!("Seedphrase konnte nicht gelesen werden: {e}"))?;
    Ok(mnemonic.to_string())
}

pub fn restore_wallet_from_seed(
    data_dir: &str,
    passphrase: &str,
    mnemonic: &str,
) -> Result<()> {
    ensure_chain_type();
    let resolved = resolve_data_dir(data_dir)?;
    let node_url = current_node_url()?;
    let mut wallet = build_wallet_backend(&resolved, &node_url)?;
    let mut wallet_config = WalletConfig::default();
    wallet_config.chain_type = Some(ChainTypes::Mainnet);
    wallet_config.check_node_api_http_addr = node_url.clone();
    wallet_config.data_file_dir = resolved.to_string_lossy().to_string();

    std::fs::create_dir_all(&wallet_config.data_file_dir)
        .with_context(|| {
            format!(
                "Konnte Wallet-Verzeichnis nicht anlegen: {}",
                wallet_config.data_file_dir
            )
        })?;

    {
        let lc = wallet
            .lc_provider()
            .map_err(|e| anyhow!("LC-Provider fehlgeschlagen: {e}"))?;
        lc.set_top_level_directory(&wallet_config.data_file_dir)
            .map_err(|e| anyhow!("Top-Level-Verzeichnis konnte nicht gesetzt werden: {e}"))?;
        lc.create_config(
            &ChainTypes::Mainnet,
            WALLET_CONFIG_FILE_NAME,
            Some(wallet_config.clone()),
            None,
            None,
        )
        .map_err(|e| anyhow!("Wallet-Konfiguration konnte nicht erstellt werden: {e}"))?;

        let phrase_clean = mnemonic.trim().to_string();
        if phrase_clean.is_empty() {
            return Err(anyhow!("Seedphrase darf nicht leer sein"));
        }
        let phrase = ZeroingString::from(phrase_clean.clone());
        lc.validate_mnemonic(phrase.clone())
            .map_err(|e| anyhow!("Seedphrase ungueltig: {e}"))?;
        lc.recover_from_mnemonic(
            phrase,
            ZeroingString::from(passphrase.to_string()),
        )
        .map_err(|e| anyhow!("Wallet konnte nicht aus Seed wiederhergestellt werden: {e}"))?;
    }

    let runtime = build_runtime(&resolved, passphrase, &node_url)?;
    let mut guard = WALLET_RUNTIME
        .lock()
        .map_err(|_| anyhow!("Wallet-Lock konnte nicht bezogen werden"))?;
    *guard = Some(runtime);
    Ok(())
}

pub fn sync() -> Result<()> {
    with_owner(|owner, mask| {
        owner.scan(mask, None, false)?;
        Ok(())
    })
}

pub fn balance() -> Result<u64> {
    with_owner(|owner, mask| {
        let (_, info) = owner.retrieve_summary_info(mask, true, 10)?;
        Ok(info.amount_currently_spendable)
    })
}

pub fn slatepack_address() -> Result<String> {
    with_owner(|owner, mask| {
        let addr = owner.get_slatepack_address(mask, 0)?;
        Ok(addr.to_string())
    })
}

pub fn send_slatepack(to: &str, amount: u64) -> Result<String> {
    if amount == 0 {
        return Err(anyhow!("Betrag muss groesser als 0 sein"));
    }
    let trimmed = to.trim();
    let recipients: Vec<SlatepackAddress> = if trimmed.is_empty() {
        Vec::new()
    } else {
        vec![SlatepackAddress::try_from(trimmed)
            .map_err(|_| anyhow!("Ungueltige Slatepack-Adresse: {}", to))?]
    };
    with_owner(move |owner, mask| {
        let init_args = InitTxArgs {
            src_acct_name: None,
            amount,
            amount_includes_fee: Some(false),
            minimum_confirmations: 10,
            max_outputs: 500,
            num_change_outputs: 1,
            selection_strategy_is_use_all: false,
            ..Default::default()
        };
        let slate = owner.init_send_tx(mask, init_args)?;
        let message = owner.create_slatepack_message(mask, &slate, Some(0), recipients)?;
        owner.tx_lock_outputs(mask, &slate)?;
        Ok(message)
    })
}

pub fn receive_slatepack(message: &str) -> Result<String> {
    let msg = message.to_string();
    with_owner(|owner, mask| {
        let slate =
            owner.slate_from_slatepack_message(mask, msg.clone(), vec![0])?;
        let decoded =
            owner.decode_slatepack_message(mask, msg.clone(), vec![0])?;
        let foreign = Foreign::new(
            owner.wallet_inst.clone(),
            mask.cloned(),
            None,
            false,
        );
        let received = foreign.receive_tx(&slate, None, None)?;
        let mut recipients = Vec::new();
        if let Some(sender) = decoded.sender {
            recipients.push(sender);
        }
        let response =
            owner.create_slatepack_message(mask, &received, Some(0), recipients)?;
        Ok(response)
    })
}

pub fn issue_invoice(amount: u64) -> Result<String> {
    if amount == 0 {
        return Err(anyhow!("Betrag muss groesser als 0 sein"));
    }
    with_owner(|owner, mask| {
        let args = IssueInvoiceTxArgs {
            amount,
            ..IssueInvoiceTxArgs::default()
        };
        let slate = owner.issue_invoice_tx(mask, args)?;
        let message = owner.create_slatepack_message(mask, &slate, Some(0), vec![])?;
        Ok(message)
    })
}

pub fn process_invoice(message: &str) -> Result<String> {
    let msg = message.to_string();
    with_owner(|owner, mask| {
        let slate =
            owner.slate_from_slatepack_message(mask, msg.clone(), vec![0])?;
        let decoded =
            owner.decode_slatepack_message(mask, msg.clone(), vec![0])?;
        let init_args = InitTxArgs {
            amount: slate.amount,
            selection_strategy_is_use_all: false,
            ..Default::default()
        };
        let processed = owner.process_invoice_tx(mask, &slate, init_args)?;
        let mut recipients = Vec::new();
        if let Some(sender) = decoded.sender {
            recipients.push(sender);
        }
        let response =
            owner.create_slatepack_message(mask, &processed, Some(0), recipients)?;
        owner.tx_lock_outputs(mask, &processed)?;
        Ok(response)
    })
}

pub fn inspect_slatepack(message: &str) -> Result<String> {
    let msg = message.to_string();
    with_owner(|owner, mask| -> Result<String, grin_wallet_libwallet::Error> {
        let slate =
            owner.slate_from_slatepack_message(mask, msg.clone(), vec![0])?;
        let slate_id = slate.id.to_string();
        let code = match slate.state {
            SlateState::Standard1 => "S1",
            SlateState::Standard2 => "S2",
            SlateState::Standard3 => "S3",
            SlateState::Invoice1 => "I1",
            SlateState::Invoice2 => "I2",
            SlateState::Invoice3 => "I3",
            SlateState::Unknown => "UN",
        }
        .to_string();
        let fee = slate.fee_fields.fee();
        let info = SlateInspectionDto {
            code,
            slate_id,
            state: format!("{:?}", slate.state),
            amount: slate.amount,
            fee,
            num_participants: slate.participant_data.len() as u16,
            kernel_excess: slate
                .tx
                .as_ref()
                .and_then(|tx| tx.kernels().first())
                .map(|k| k.excess().to_hex()),
        };
        serde_json::to_string(&info)
            .map_err(|e| grin_wallet_libwallet::Error::Format(e.to_string()))
    })
}

pub fn transaction_slatepack(tx_id: u32) -> Result<String> {
    with_owner(|owner, mask| {
        let slate = owner
            .get_stored_tx(mask, Some(tx_id), None)?
            .ok_or_else(|| {
                grin_wallet_libwallet::Error::StoredTx(format!(
                    "Keine Slatepack-Daten fuer Tx {tx_id} gefunden"
                ))
            })?;
        let message = owner.create_slatepack_message(mask, &slate, Some(0), vec![])?;
        Ok(message)
    })
}

pub fn finalize_slatepack(message: &str, post: bool, fluff: bool) -> Result<String> {
    let msg = message.to_string();
    with_owner(|owner, mask| {
        let slate =
            owner.slate_from_slatepack_message(mask, msg.clone(), vec![0])?;
        let finalized = owner.finalize_tx(mask, &slate)?;
        if post {
            owner.post_tx(mask, &finalized, fluff)?;
        }
        let result =
            owner.create_slatepack_message(mask, &finalized, Some(0), vec![])?;
        Ok(result)
    })
}

pub fn wallet_info() -> Result<String> {
    with_runtime_mut(|runtime| {
        let mask_ref = runtime.keychain_mask.as_ref();
        let (refreshed, info) =
            runtime.owner.retrieve_summary_info(mask_ref, true, 10)?;
        let dto = WalletInfoDto {
            refreshed_from_node: refreshed,
            info,
            active_account: runtime.active_account.clone(),
        };
        to_json(&dto)
    })
}

pub fn list_transactions(refresh_from_node: bool) -> Result<String> {
    with_runtime_mut(|runtime| {
        let mask_ref = runtime.keychain_mask.as_ref();
        let node_height = runtime.owner.node_height(mask_ref)?.height;
        let (_, entries) =
            runtime
                .owner
                .retrieve_txs(mask_ref, refresh_from_node, None, None, None)?;
        let (_, mappings) = runtime.owner.retrieve_outputs(
            mask_ref,
            true,
            refresh_from_node,
            None,
        )?;
        let mut confirmations_map: HashMap<u32, u64> = HashMap::new();
        for mapping in mappings {
            if let Some(tx_id) = mapping.output.tx_log_entry {
                let height = mapping.output.height;
                let confirmations = if height == 0 || height > node_height {
                    0
                } else {
                    1 + (node_height - height)
                };
                confirmations_map
                    .entry(tx_id)
                    .and_modify(|existing| {
                        if confirmations < *existing {
                            *existing = confirmations;
                        }
                    })
                    .or_insert(confirmations);
            }
        }
        let txs: Vec<TransactionDto> = entries
            .into_iter()
            .map(|entry| {
                let confirmations = confirmations_map.get(&entry.id).copied().unwrap_or(0);
                TransactionDto::from_entry(entry, confirmations)
            })
            .collect();
        to_json(&txs)
    })
}

pub fn list_outputs(include_spent: bool, refresh_from_node: bool) -> Result<String> {
    with_runtime_mut(|runtime| {
        let mask_ref = runtime.keychain_mask.as_ref();
        let node_height = runtime.owner.node_height(mask_ref)?.height;
        let (_, mappings) = runtime.owner.retrieve_outputs(
            mask_ref,
            include_spent,
            refresh_from_node,
            None,
        )?;
        let outputs: Vec<OutputDto> = mappings
            .into_iter()
            .map(|mapping| OutputDto::from_mapping(mapping, node_height))
            .collect();
        to_json(&outputs)
    })
}

pub fn cancel_tx(tx_id: u32) -> Result<()> {
    with_runtime_mut(|runtime| {
        let args = CancelArgs {
            tx_id: Some(tx_id),
            tx_slate_id: None,
            tx_id_string: tx_id.to_string(),
        };
        command::cancel(&mut runtime.owner, runtime.keychain_mask.as_ref(), args)?;
        Ok(())
    })
}

pub fn repost_tx(tx_id: u32, fluff: bool) -> Result<()> {
    with_runtime_mut(|runtime| {
        let args = RepostArgs {
            id: tx_id,
            dump_file: None,
            fluff,
        };
        command::repost(&mut runtime.owner, runtime.keychain_mask.as_ref(), args)?;
        Ok(())
    })
}

pub fn scan(
    delete_unconfirmed: bool,
    start_height: Option<u64>,
    backwards_from_tip: Option<u64>,
) -> Result<String> {
    with_runtime_mut(|runtime| {
        let args = CheckArgs {
            delete_unconfirmed,
            start_height,
            backwards_from_tip,
        };
        command::scan(&mut runtime.owner, runtime.keychain_mask.as_ref(), args)?;
        let dto = ScanResultDto {
            delete_unconfirmed,
            start_height,
            backwards_from_tip,
            performed_at_epoch_secs: epoch_secs(),
        };
        to_json(&dto)
    })
}

pub fn list_accounts() -> Result<String> {
    with_runtime_mut(|runtime| {
        let mask_ref = runtime.keychain_mask.as_ref();
        let accounts = runtime.owner.accounts(mask_ref)?;
        let dto: Vec<AccountDto> = accounts
            .into_iter()
            .map(|acct| AccountDto {
                label: acct.label.clone(),
                path: acct.path.to_bip_32_string(),
                is_active: acct.label == runtime.active_account,
            })
            .collect();
        to_json(&dto)
    })
}

pub fn create_account(label: &str) -> Result<String> {
    let cleaned = label.trim();
    if cleaned.is_empty() {
        return Err(anyhow!("Account-Name darf nicht leer sein"));
    }
    with_runtime_mut(|runtime| {
        let mask_ref = runtime.keychain_mask.as_ref();
        let identifier =
            runtime.owner.create_account_path(mask_ref, cleaned)?;
        let dto = AccountDto {
            label: cleaned.to_string(),
            path: identifier.to_bip_32_string(),
            is_active: false,
        };
        to_json(&dto)
    })
}

pub fn set_active_account(label: &str) -> Result<String> {
    let cleaned = label.trim();
    if cleaned.is_empty() {
        return Err(anyhow!("Account-Name darf nicht leer sein"));
    }
    with_runtime_mut(|runtime| {
        let mask_ref = runtime.keychain_mask.as_ref();
        runtime
            .owner
            .set_active_account(mask_ref, cleaned)?;
        runtime.active_account = cleaned.to_string();
        let accounts = runtime.owner.accounts(mask_ref)?;
        let path = accounts
            .into_iter()
            .find(|acct| acct.label == runtime.active_account)
            .map(|acct| acct.path.to_bip_32_string())
            .unwrap_or_else(|| "m/0/0".to_string());
        let dto = AccountDto {
            label: runtime.active_account.clone(),
            path,
            is_active: true,
        };
        to_json(&dto)
    })
}

pub fn active_account() -> Result<String> {
    with_runtime_mut(|runtime| Ok(runtime.active_account.clone()))
}

pub fn payment_proof(tx_id: u32) -> Result<String> {
    with_runtime_mut(|runtime| {
        let mask_ref = runtime.keychain_mask.as_ref();
        let proof = runtime.owner.retrieve_payment_proof(
            mask_ref,
            true,
            Some(tx_id),
            None,
        )?;
        let dto = PaymentProofDto { tx_id, proof };
        to_json(&dto)
    })
}

pub fn verify_payment_proof(serialized: &str) -> Result<String> {
    let proof: PaymentProof = serde_json::from_str(serialized)
        .map_err(|e| anyhow!("Payment Proof konnte nicht gelesen werden: {e}"))?;
    with_runtime_mut(|runtime| {
        let mask_ref = runtime.keychain_mask.as_ref();
        let (is_sender, is_recipient) =
            runtime.owner.verify_payment_proof(mask_ref, &proof)?;
        let dto = PaymentProofVerificationDto {
            is_sender,
            is_recipient,
        };
        to_json(&dto)
    })
}

fn with_owner<R, F>(op: F) -> Result<R>
where
    F: FnOnce(&mut OwnerApi, Option<&SecretKey>) -> Result<R, grin_wallet_libwallet::Error>,
{
    with_runtime_mut(|runtime| {
        let mask_ref = runtime.keychain_mask.as_ref();
        op(&mut runtime.owner, mask_ref).map_err(|e| anyhow!(e))
    })
}

fn with_runtime_mut<R, F>(op: F) -> Result<R>
where
    F: FnOnce(&mut WalletRuntime) -> Result<R>,
{
    let mut guard = WALLET_RUNTIME
        .lock()
        .map_err(|_| anyhow!("Wallet-Lock konnte nicht bezogen werden"))?;
    let runtime = guard
        .as_mut()
        .ok_or_else(|| anyhow!("Wallet ist noch nicht initialisiert. Bitte wallet_init_or_open zuerst aufrufen."))?;
    op(runtime)
}

fn tx_direction(tx_type: &TxLogEntryType) -> &'static str {
    match tx_type {
        TxLogEntryType::TxSent | TxLogEntryType::TxSentCancelled => "sent",
        TxLogEntryType::TxReverted => "reverted",
        _ => "received",
    }
}

fn tx_status(entry: &TxLogEntry) -> &'static str {
    match entry.tx_type {
        TxLogEntryType::TxReceivedCancelled
        | TxLogEntryType::TxSentCancelled => "cancelled",
        TxLogEntryType::TxReverted => "reverted",
        _ => {
            if entry.confirmed {
                "confirmed"
            } else {
                "pending"
            }
        }
    }
}

fn to_json<T: Serialize>(value: &T) -> Result<String> {
    serde_json::to_string(value).map_err(|e| anyhow!("JSON konnte nicht erzeugt werden: {e}"))
}

fn epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn resolve_data_dir(data_dir: &str) -> Result<PathBuf> {
    let path = Path::new(data_dir);
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Ok(std::env::current_dir()
            .context("Arbeitsverzeichnis konnte nicht bestimmt werden")?
            .join(path))
    }
}

fn build_runtime(data_dir: &Path, passphrase: &str, node_url: &str) -> Result<WalletRuntime> {
    let mut wallet = build_wallet_backend(data_dir, node_url)?;
    let mut wallet_config = WalletConfig::default();
    wallet_config.chain_type = Some(ChainTypes::Mainnet);
    wallet_config.check_node_api_http_addr = node_url.to_owned();
    wallet_config.data_file_dir = data_dir.to_string_lossy().to_string();
    wallet_config.api_secret_path = None;
    wallet_config.node_api_secret_path = None;
    wallet_config.owner_api_include_foreign = Some(false);

    std::fs::create_dir_all(&wallet_config.data_file_dir)
        .with_context(|| format!("Konnte Wallet-Verzeichnis nicht anlegen: {}", wallet_config.data_file_dir))?;

    {
        let lc = wallet.lc_provider().map_err(|e| anyhow!("LC-Provider fehlgeschlagen: {e}"))?;
        lc.set_top_level_directory(&wallet_config.data_file_dir)
            .map_err(|e| anyhow!("Top-Level-Verzeichnis konnte nicht gesetzt werden: {e}"))?;
    }

    let wallet_arc: WalletBackendInstance = Arc::new(GrinMutex::new(wallet));
    let mut owner_api = Owner::new(wallet_arc.clone(), None);

    let wallet_exists = {
        let mut lock = wallet_arc.lock();
        let lc = lock.lc_provider().map_err(|e| anyhow!("LC-Provider fehlgeschlagen: {e}"))?;
        lc.wallet_exists(None).map_err(|e| anyhow!("Wallet-Existenz konnte nicht geprueft werden: {e}"))?
    };

    let password = ZeroingString::from(passphrase);
    let global_args = command::GlobalArgs {
        account: "default".to_string(),
        api_secret: None,
        node_api_secret: None,
        show_spent: false,
        password: Some(password.clone()),
        tls_conf: None,
    };

    if !wallet_exists {
        let init_args = command::InitArgs {
            list_length: 24,
            password: password.clone(),
            config: wallet_config.clone(),
            recovery_phrase: None,
            restore: false,
        };
        command::init(&mut owner_api, &global_args, init_args, false)
            .map_err(|e| anyhow!("Wallet-Initialisierung fehlgeschlagen: {e}"))?;
    }

    let keychain_mask = {
        let mut lock = wallet_arc.lock();
        let lc = lock.lc_provider().map_err(|e| anyhow!("LC-Provider fehlgeschlagen: {e}"))?;
        let mask = lc
            .open_wallet(None, password, false, false)
            .map_err(|e| anyhow!("Wallet konnte nicht geoefnet werden: {e}"))?;
        let wallet_inst = lc.wallet_inst().map_err(|e| anyhow!("Wallet-Instanz konnte nicht geladen werden: {e}"))?;
        wallet_inst
            .set_parent_key_id_by_name(&global_args.account)
            .map_err(|e| anyhow!("Account 'default' konnte nicht gesetzt werden: {e}"))?;
        mask
    };

    Ok(WalletRuntime {
        owner: owner_api,
        keychain_mask,
        _data_dir: data_dir.to_path_buf(),
        _node_url: node_url.to_owned(),
        active_account: global_args.account,
    })
}

fn build_wallet_backend(
    _data_dir: &Path,
    node_url: &str,
) -> Result<
    Box<
        dyn WalletInst<
            'static,
            DefaultLCProvider<'static, HTTPNodeClient, ExtKeychain>,
            HTTPNodeClient,
            ExtKeychain,
        >,
    >,
> {
    let node_client = HTTPNodeClient::new(node_url, None)
        .map_err(|e| anyhow!("HTTPNodeClient konnte nicht erstellt werden: {e}"))?;
    let wallet_backend = DefaultWalletImpl::<'static, HTTPNodeClient>::new(node_client.clone())
        .map_err(|e| anyhow!("Wallet-Backend konnte nicht erstellt werden: {e}"))?;
    Ok(Box::new(wallet_backend))
}

fn ensure_chain_type() {
    CHAIN_INIT.call_once(|| {
        global::init_global_chain_type(ChainTypes::Mainnet);
        global::set_local_chain_type(ChainTypes::Mainnet);
        global::init_global_accept_fee_base(WalletConfig::default_accept_fee_base());
    });
}
