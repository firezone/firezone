use super::{ControllerRequest, CtlrTx, Error};

/// Show a notification in the bottom right of the screen
pub(crate) fn show_notification(title: &str, body: &str) -> Result<(), Error> {
    // TODO
    Ok(())
}

/// Show a notification that signals `Controller` when clicked
pub(crate) fn show_clickable_notification(
    title: &str,
    body: &str,
    tx: CtlrTx,
    req: ControllerRequest,
) -> Result<(), Error> {
    // TODO
    Ok(())
}
