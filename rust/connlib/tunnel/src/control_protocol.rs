use connlib_shared::messages::{RequestConnection, ReuseConnection};
mod client;
mod gateway;

#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(clippy::large_enum_variant)]
pub enum Request {
    NewConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
}
