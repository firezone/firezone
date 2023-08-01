//! Main connlib library for gateway.
use control::ControlPlane;
use messages::EgressMessages;
use messages::IngressMessages;

mod control;
mod messages;

/// Session type for gateway.
///
/// For more information see libs_common docs on [Session][libs_common::Session].
// TODO: Still working on gateway messages
pub type Session<CB> = libs_common::Session<
    ControlPlane<CB>,
    IngressMessages,
    EgressMessages,
    IngressMessages,
    IngressMessages,
    CB,
>;

pub use libs_common::{messages::ResourceDescription, Callbacks, Error};
