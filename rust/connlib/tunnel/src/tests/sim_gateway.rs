use super::{
    reference::{private_key, PrivateKey},
    sim_net::{any_port, dual_ip_stack, host, Host},
    strategies::latency,
};
use crate::GatewayState;
use connlib_shared::DomainName;
use ip_packet::IpPacket;
use proptest::prelude::*;
use snownet::Transmit;
use std::{
    collections::{BTreeMap, HashSet, VecDeque},
    net::IpAddr,
    time::Instant,
};

/// Simulation state for a particular client.
pub(crate) struct SimGateway {
    pub(crate) sut: GatewayState,

    pub(crate) received_icmp_requests: VecDeque<IpPacket<'static>>,

    buffer: Vec<u8>,
}

impl SimGateway {
    pub(crate) fn new(sut: GatewayState) -> Self {
        Self {
            sut,
            received_icmp_requests: Default::default(),
            buffer: vec![0u8; (1 << 16) - 1],
        }
    }

    pub(crate) fn receive(
        &mut self,
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
        transmit: Transmit,
        now: Instant,
    ) -> Option<Transmit<'static>> {
        let packet = self
            .sut
            .decapsulate(
                transmit.dst,
                transmit.src.unwrap(),
                &transmit.payload,
                now,
                &mut self.buffer,
            )?
            .to_owned();

        self.on_received_packet(global_dns_records, packet, now)
    }

    /// Process an IP packet received on the gateway.
    fn on_received_packet(
        &mut self,
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
        packet: IpPacket<'_>,
        now: Instant,
    ) -> Option<Transmit<'static>> {
        let packet = packet.to_owned();

        if packet.as_icmp().is_some() {
            self.received_icmp_requests.push_back(packet.clone());

            let echo_response = ip_packet::make::icmp_response_packet(packet);
            let transmit = self.sut.encapsulate(echo_response, now)?.into_owned();

            return Some(transmit);
        }

        if packet.as_udp().is_some() {
            let response = ip_packet::make::dns_ok_response(packet, |name| {
                global_dns_records.get(name).cloned().into_iter().flatten()
            });

            let transmit = self.sut.encapsulate(response, now)?.into_owned();

            return Some(transmit);
        }

        panic!("Unhandled packet")
    }
}

/// Reference state for a particular gateway.
#[derive(Debug, Clone)]
pub struct RefGateway {
    pub(crate) key: PrivateKey,
}

impl RefGateway {
    /// Initialize the [`GatewayState`].
    ///
    /// This simulates receiving the `init` message from the portal.
    pub(crate) fn init(self) -> SimGateway {
        SimGateway::new(GatewayState::new(self.key))
    }
}

pub(crate) fn ref_gateway_host() -> impl Strategy<Value = Host<RefGateway>> {
    host(
        dual_ip_stack(),
        any_port(),
        ref_gateway(),
        latency(200), // We assume gateways have a somewhat decent Internet connection.
    )
}

fn ref_gateway() -> impl Strategy<Value = RefGateway> {
    private_key().prop_map(move |key| RefGateway { key })
}
