use std::{
    cell::Cell,
    net::{IpAddr, SocketAddr},
};

use connlib_model::{ClientId, ResourceId};
use ip_packet::{IpPacket, Protocol, UnsupportedProtocol};

thread_local! {
    static CURRENT_FLOW: Cell<Option<FlowData>> = const { Cell::new(None) };
}

#[derive(Debug, Default)]
pub struct FlowTracker {}

impl FlowTracker {
    pub fn new_inbound_tun<'a>(&'a mut self, packet: &IpPacket) -> CurrentFlowGuard<'a> {
        let current = CURRENT_FLOW.replace(Some(FlowData::InboundTun {
            src_ip: packet.source(),
            dst_ip: packet.destination(),
            src_proto: packet.source_protocol(),
            dst_proto: packet.destination_protocol(),
        }));
        debug_assert!(
            current.is_none(),
            "at most 1 flow should be active at any time"
        );

        CurrentFlowGuard { inner: self }
    }

    pub fn new_inbound_wireguard<'a>(
        &'a mut self,
        local: SocketAddr,
        remote: SocketAddr,
        payload: &[u8],
    ) -> CurrentFlowGuard<'a> {
        let current = CURRENT_FLOW.replace(Some(FlowData::InboundWireGuard {
            local,
            remote,
            payload_len: payload.len(),
        }));
        debug_assert!(
            current.is_none(),
            "at most 1 flow should be active at any time"
        );

        CurrentFlowGuard { inner: self }
    }
}

pub mod inbound_wg {
    use super::*;

    pub fn record_client(cid: ClientId) {}
    pub fn record_resource(rid: ResourceId) {}
    pub fn record_decrypted_packet(packet: &IpPacket) {}
    pub fn record_translated_packet(packet: &IpPacket) {}
    pub fn record_icmp_error(packet: &IpPacket) {}
}

pub mod inbound_tun {
    use super::*;

    pub fn record_client(cid: ClientId) {}
    pub fn record_resource(rid: ResourceId) {}
    pub fn record_translated_packet(packet: &IpPacket) {}
    pub fn record_wireguard_packet(local: Option<SocketAddr>, remote: SocketAddr, payload: &[u8]) {}
}

pub struct CurrentFlowGuard<'a> {
    inner: &'a mut FlowTracker,
}

impl<'a> Drop for CurrentFlowGuard<'a> {
    fn drop(&mut self) {
        let Some(current_flow) = CURRENT_FLOW.replace(None) else {
            debug_assert!(
                false,
                "Should always have a current flow if an `InboundFlowGuard` is alive"
            );

            return;
        };

        // TODO: Insert flow into flow tracker
    }
}

enum FlowData {
    InboundWireGuard {
        local: SocketAddr,
        remote: SocketAddr,
        payload_len: usize,
    },
    InboundTun {
        src_ip: IpAddr,
        dst_ip: IpAddr,
        src_proto: Result<Protocol, UnsupportedProtocol>,
        dst_proto: Result<Protocol, UnsupportedProtocol>,
    },
}
