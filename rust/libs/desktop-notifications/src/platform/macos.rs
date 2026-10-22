use anyhow::Result;
use url::Url;

#[expect(clippy::unused_async, reason = "Signature must match other platforms.")]
pub(crate) async fn show(
    _app_id: &str,
    _title: &str,
    _body: &str,
    _open_url: Option<&Url>,
) -> Result<()> {
    tracing::warn!("Notifications are not implemented on macOS");

    Ok(())
}
