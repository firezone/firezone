use super::{
    reference::{private_key, PrivateKey},
    sim_net::{any_port, dual_ip_stack, host, Host},
    sim_relay::{map_explode, SimRelay},
    strategies::latency,
};
use crate::DomainName;
use crate::GatewayState;
use chrono::{DateTime, Utc};
use connlib_model::{GatewayId, RelayId};
use ip_packet::{IcmpEchoHeader, Icmpv4Type, Icmpv6Type, IpPacket};
use proptest::prelude::*;
use snownet::{EncryptBuffer, Transmit};
use std::{
    collections::{BTreeMap, BTreeSet},
    net::IpAddr,
    time::Instant,
};

/// Simulation state for a particular client.
pub(crate) struct SimGateway {
    id: GatewayId,
    pub(crate) sut: GatewayState,

    /// The received ICMP packets, indexed by our custom ICMP payload.
    pub(crate) received_icmp_requests: BTreeMap<u64, IpPacket>,

    enc_buffer: EncryptBuffer,
}

impl SimGateway {
    pub(crate) fn new(id: GatewayId, sut: GatewayState) -> Self {
        Self {
            id,
            sut,
            received_icmp_requests: Default::default(),
            enc_buffer: EncryptBuffer::new((1 << 16) - 1),
        }
    }

    pub(crate) fn receive(
        &mut self,
        global_dns_records: &BTreeMap<DomainName, BTreeSet<IpAddr>>,
        transmit: Transmit,
        now: Instant,
        utc_now: DateTime<Utc>,
    ) -> Option<Transmit<'static>> {
        let Some(packet) =
            self.sut
                .decapsulate(transmit.dst, transmit.src.unwrap(), &transmit.payload, now)
        else {
            self.sut.handle_timeout(now, utc_now);
            return None;
        };

        self.on_received_packet(global_dns_records, packet, now)
    }

    /// Process an IP packet received on the gateway.
    fn on_received_packet(
        &mut self,
        global_dns_records: &BTreeMap<DomainName, BTreeSet<IpAddr>>,
        packet: IpPacket,
        now: Instant,
    ) -> Option<Transmit<'static>> {
        // TODO: Instead of handling these things inline, here, should we dispatch them via `RoutingTable`?

        if let Some(icmp) = packet.as_icmpv4() {
            if let Icmpv4Type::EchoRequest(echo) = icmp.icmp_type() {
                return self.handle_icmp_request(&packet, echo, icmp.payload(), now);
            }
        }

        if let Some(icmp) = packet.as_icmpv6() {
            if let Icmpv6Type::EchoRequest(echo) = icmp.icmp_type() {
                return self.handle_icmp_request(&packet, echo, icmp.payload(), now);
            }
        }

        if packet.as_udp().is_some() {
            let response = ip_packet::make::dns_ok_response(packet, |name| {
                global_dns_records.get(name).cloned().into_iter().flatten()
            });

            let transmit = self
                .sut
                .encapsulate(response, now, &mut self.enc_buffer)?
                .to_transmit(&self.enc_buffer)
                .into_owned();

            return Some(transmit);
        }

        tracing::error!(?packet, "Unhandled packet");
        None
    }

    pub(crate) fn update_relays<'a>(
        &mut self,
        to_remove: impl Iterator<Item = RelayId>,
        to_add: impl Iterator<Item = (&'a RelayId, &'a Host<SimRelay>)> + 'a,
        now: Instant,
    ) {
        self.sut.update_relays(
            to_remove.collect(),
            map_explode(to_add, format!("gateway_{}", self.id)).collect(),
            now,
        )
    }

    fn handle_icmp_request(
        &mut self,
        packet: &IpPacket,
        echo: IcmpEchoHeader,
        payload: &[u8],
        now: Instant,
    ) -> Option<Transmit<'static>> {
        let echo_id = u64::from_be_bytes(*payload.first_chunk().unwrap());
        self.received_icmp_requests.insert(echo_id, packet.clone());

        tracing::debug!(%echo_id, "Received ICMP request");

        let echo_response = ip_packet::make::icmp_reply_packet(
            packet.destination(),
            packet.source(),
            echo.seq,
            echo.id,
            payload,
        )
        .expect("src and dst are taken from incoming packet");
        let transmit = self
            .sut
            .encapsulate(echo_response, now, &mut self.enc_buffer)?
            .to_transmit(&self.enc_buffer)
            .into_owned();

        Some(transmit)
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
    pub(crate) fn init(self, id: GatewayId) -> SimGateway {
        SimGateway::new(id, GatewayState::new(self.key.0)) // Cheating a bit here by reusing the key as seed.
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
