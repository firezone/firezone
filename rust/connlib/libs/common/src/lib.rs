//! This crates contains shared types and behavior between all the other libraries.
//!
//! This includes types provided by external crates, i.e. [boringtun] to make sure that
//! we are using the same version across our own crates.

pub mod error;
pub mod error_type;

mod session;

pub mod control;
pub mod messages;

pub use error::ConnlibError as Error;
pub use error::Result;

pub use session::{Callbacks, ControlSession, ResourceList, Session, TunnelAddresses};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const LIB_NAME: &str = "connlib";

pub fn get_user_agent() -> String {
    let info = os_info::get();
    let os_type = info.os_type();
    let os_version = info.version();
    let lib_version = VERSION;
    let lib_name = LIB_NAME;
    format!("{os_type}/{os_version} {lib_name}/{lib_version}")
}
