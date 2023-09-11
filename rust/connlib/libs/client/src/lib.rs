//! Main connlib library for clients.
use control::ControlPlane;
use messages::EgressMessages;
use messages::IngressMessages;

mod control;
pub mod file_logger;
mod messages;

/// Session type for clients.
///
/// For more information see libs_common docs on [Session][libs_common::Session].
pub type Session<CB> = libs_common::Session<
    ControlPlane<CB>,
    IngressMessages,
    EgressMessages,
    ReplyMessages,
    Messages,
    CB,
>;

pub use libs_common::{
    get_device_id, get_user_agent, messages::ResourceDescription, Callbacks, Error,
};
use messages::Messages;
use messages::ReplyMessages;
