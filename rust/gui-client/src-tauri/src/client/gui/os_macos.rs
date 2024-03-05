use super::{ControllerRequest, CtlrTx, Error};

/// Show a notification in the bottom right of the screen
pub(crate) fn show_notification(_title: &str, _body: &str) -> Result<(), Error> {
    unimplemented!()
}

/// Show a notification that signals `Controller` when clicked
pub(crate) fn show_clickable_notification(
    _title: &str,
    _body: &str,
    _tx: CtlrTx,
    _req: ControllerRequest,
) -> Result<(), Error> {
    unimplemented!()
}