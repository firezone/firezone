use std::{fmt, hash::Hash};

use connlib_shared::{
    messages::{RequestConnection, ReuseConnection},
    Callbacks,
};

use crate::Tunnel;

mod client;
pub mod gateway;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    NewConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
}

impl<CB, TRoleState, TRole, TId> Tunnel<CB, TRoleState, TRole, TId>
where
    CB: Callbacks + 'static,
    TId: Eq + Hash + Copy + fmt::Display,
{
    pub fn add_ice_candidate(&mut self, conn_id: TId, ice_candidate: String) {
        self.connections_state
            .node
            .add_remote_candidate(conn_id, ice_candidate);
    }
}
