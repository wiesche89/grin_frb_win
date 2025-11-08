use anyhow::{anyhow, Result};
use crate::wallet;
use flutter_rust_bridge::frb;


#[frb]
pub fn set_node_url(url: String) -> Result<()> {
    wallet::update_node_url(&url)?;
    Ok(())
}

#[frb]
pub fn get_node_url() -> Result<String> {
    wallet::current_node_url()
}

#[frb]
pub async fn get_node_tip() -> Result<u64> {
    run_blocking(|| wallet::node_tip()).await
}


#[frb]
pub async fn wallet_init_or_open(data_dir: String, passphrase: String) -> Result<()> {
    let dir = data_dir.trim().to_string();
    run_blocking(move || wallet::init_or_open(&dir, &passphrase)).await
}

#[frb]
pub async fn wallet_create(data_dir: String, passphrase: String, mnemonic_length: usize) -> Result<String> {
    let dir = data_dir.trim().to_string();
    run_blocking(move || wallet::create_wallet(&dir, &passphrase, mnemonic_length)).await
}

#[frb]
pub async fn wallet_seed_phrase(data_dir: String, passphrase: String) -> Result<String> {
    let dir = data_dir.trim().to_string();
    run_blocking(move || wallet::seed_phrase(&dir, &passphrase)).await
}

#[frb]
pub async fn wallet_restore_from_seed(
    data_dir: String,
    passphrase: String,
    phrase: String,
) -> Result<()> {
    let dir = data_dir.trim().to_string();
    let seed = phrase.trim().to_string();
    run_blocking(move || wallet::restore_wallet_from_seed(&dir, &passphrase, &seed)).await
}

#[frb]
pub async fn wallet_get_address() -> Result<String> {
    run_blocking(|| wallet::slatepack_address()).await
}

#[frb]
pub async fn wallet_sync() -> Result<()> {
    run_blocking(|| wallet::sync()).await
}

#[frb]
pub async fn wallet_get_balance() -> Result<u64> {
    run_blocking(|| wallet::balance()).await
}

#[frb]
pub async fn wallet_send_slatepack(to: String, amount_nano: u64) -> Result<String> {
    let recipient = to.trim().to_string();
    run_blocking(move || wallet::send_slatepack(&recipient, amount_nano)).await
}

#[frb]
pub async fn wallet_issue_invoice(amount_nano: u64) -> Result<String> {
    run_blocking(move || wallet::issue_invoice(amount_nano)).await
}

#[frb]
pub async fn wallet_receive_slatepack(message: String) -> Result<String> {
    run_blocking(move || wallet::receive_slatepack(&message)).await
}

#[frb]
pub async fn wallet_process_invoice(message: String) -> Result<String> {
    run_blocking(move || wallet::process_invoice(&message)).await
}

#[frb]
pub async fn wallet_inspect_slatepack(message: String) -> Result<String> {
    run_blocking(move || wallet::inspect_slatepack(&message)).await
}

#[frb]
pub async fn wallet_finalize_slatepack(message: String, post_tx: bool, fluff: bool) -> Result<String> {
    run_blocking(move || wallet::finalize_slatepack(&message, post_tx, fluff)).await
}

#[frb]
pub async fn wallet_info() -> Result<String> {
    run_blocking(|| wallet::wallet_info()).await
}

#[frb]
pub async fn wallet_list_transactions(refresh_from_node: bool) -> Result<String> {
    run_blocking(move || wallet::list_transactions(refresh_from_node)).await
}

#[frb]
pub async fn wallet_list_outputs(include_spent: bool, refresh_from_node: bool) -> Result<String> {
    run_blocking(move || wallet::list_outputs(include_spent, refresh_from_node)).await
}

#[frb]
pub async fn wallet_cancel_tx(tx_id: u32) -> Result<()> {
    run_blocking(move || wallet::cancel_tx(tx_id)).await
}

#[frb]
pub async fn wallet_repost_tx(tx_id: u32, fluff: bool) -> Result<()> {
    run_blocking(move || wallet::repost_tx(tx_id, fluff)).await
}

#[frb]
pub async fn wallet_scan(delete_unconfirmed: bool, start_height: Option<u64>, backwards_from_tip: Option<u64>) -> Result<String> {
    run_blocking(move || wallet::scan(delete_unconfirmed, start_height, backwards_from_tip)).await
}

#[frb]
pub async fn wallet_list_accounts() -> Result<String> {
    run_blocking(|| wallet::list_accounts()).await
}

#[frb]
pub async fn wallet_create_account(label: String) -> Result<String> {
    run_blocking(move || wallet::create_account(&label)).await
}

#[frb]
pub async fn wallet_set_active_account(label: String) -> Result<String> {
    run_blocking(move || wallet::set_active_account(&label)).await
}

#[frb]
pub async fn wallet_active_account() -> Result<String> {
    run_blocking(|| wallet::active_account()).await
}

#[frb]
pub async fn wallet_payment_proof(tx_id: u32) -> Result<String> {
    run_blocking(move || wallet::payment_proof(tx_id)).await
}

#[frb]
pub async fn wallet_transaction_slatepack(tx_id: u32) -> Result<String> {
    run_blocking(move || wallet::transaction_slatepack(tx_id)).await
}

#[frb]
pub async fn wallet_verify_payment_proof(payload: String) -> Result<String> {
    run_blocking(move || wallet::verify_payment_proof(&payload)).await
}

async fn run_blocking<F, T>(f: F) -> Result<T>
where
    F: FnOnce() -> Result<T> + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| anyhow!("Hintergrund-Task fehlgeschlagen: {e}"))?
}
