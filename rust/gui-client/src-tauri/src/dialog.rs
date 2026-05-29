use anyhow::{Context as _, Result};
use native_dialog::{DialogBuilder, MessageLevel};

pub fn error(body: &str) -> Result<()> {
    DialogBuilder::message()
        .set_title("Firezone Error")
        .set_text(body)
        .set_level(MessageLevel::Error)
        .alert()
        .show()
        .context("Failed to show error dialog")?;

    Ok(())
}

pub fn info(body: &str) -> Result<()> {
    DialogBuilder::message()
        .set_title("Firezone")
        .set_text(body)
        .set_level(MessageLevel::Info)
        .alert()
        .show()
        .context("Failed to show info dialog")?;

    Ok(())
}
