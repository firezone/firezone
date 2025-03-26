use anyhow::Result;

pub const GENERIC_MSG: &str = "An unexpected error occurred. Please try restarting Firezone. If the issue persists, contact your administrator.";

/// Blocks the thread and shows an error dialog
///
/// Doesn't play well with async, only use this if we're bailing out of the
/// entire process.
pub fn show_error_dialog(msg: String) -> Result<()> {
    // I tried the Tauri dialogs and for some reason they don't show our
    // app icon.
    native_dialog::MessageDialog::new()
        .set_title("Firezone Error")
        .set_text(&msg)
        .set_type(native_dialog::MessageType::Error)
        .show_alert()?;
    Ok(())
}
