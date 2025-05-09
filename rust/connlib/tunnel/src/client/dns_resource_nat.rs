use std::{
    collections::{BTreeMap, VecDeque, btree_map::Entry},
    net::IpAddr,
    time::{Duration, Instant},
};

use connlib_model::{GatewayId, ResourceId};
use dns_types::DomainName;
use ip_packet::IpPacket;

use crate::{p2p_control, unique_packet_buffer::UniquePacketBuffer};

/// Tracks the domains for which we have set up a NAT per gateway.
///
/// The IPs for DNS resources get assigned on the client.
/// In order to route them to the actual resource, the gateway needs to set up a NAT table.
/// Until the NAT is set up, packets sent to these resources are effectively black-holed.
#[derive(Default)]
pub struct DnsResourceNat {
    inner: BTreeMap<(GatewayId, DomainName), State>,
}

impl DnsResourceNat {
    pub fn update(
        &mut self,
        domain: DomainName,
        gid: GatewayId,
        rid: ResourceId,
        proxy_ips: &[IpAddr],
        packets_for_domain: VecDeque<IpPacket>,
        now: Instant,
    ) -> Option<IpPacket> {
        match self.inner.entry((gid, domain.clone())) {
            Entry::Vacant(v) => {
                let mut buffered_packets =
                    UniquePacketBuffer::with_capacity_power_of_2(5, "dns-resource-nat-initial"); // 2^5 = 32
                buffered_packets.extend(packets_for_domain);

                v.insert(State::Pending {
                    sent_at: now,
                    buffered_packets,

                    should_buffer: true,
                });
            }
            Entry::Occupied(mut o) => {
                let state = o.get_mut();

                match state {
                    State::Confirmed => return None,
                    State::Failed => return None,
                    State::Recreating { should_buffer } => {
                        let mut buffered_packets = UniquePacketBuffer::with_capacity_power_of_2(
                            5, // 2^5 = 32
                            "dns-resource-nat-recreating",
                        );
                        buffered_packets.extend(packets_for_domain);

                        *state = State::Pending {
                            sent_at: now,
                            buffered_packets,
                            should_buffer: *should_buffer,
                        };
                    }
                    State::Pending {
                        sent_at,
                        buffered_packets,
                        ..
                    } => {
                        let time_since_last_attempt = now.duration_since(*sent_at);
                        buffered_packets.extend(packets_for_domain);

                        if time_since_last_attempt < Duration::from_secs(2) {
                            return None;
                        }

                        *sent_at = now;
                    }
                }
            }
        }

        let packet =
            match p2p_control::dns_resource_nat::assigned_ips(rid, domain, proxy_ips.to_vec()) {
                Ok(packet) => packet,
                Err(e) => {
                    tracing::warn!("Failed to create IP packet for `AssignedIp`s event: {e:#}");
                    return None;
                }
            };

        Some(packet)
    }

    /// Recreate the DNS resource NAT state for a given domain.
    ///
    /// This will trigger the client to submit another `AssignedIp`s event to the Gateway.
    /// On the Gateway, such an event causes a new DNS resolution.
    ///
    /// We call this function every time a client issues a DNS query for a certain domain.
    /// Coupling this behaviour together allows a client to refresh the DNS resolution of a DNS resource on the Gateway
    /// through local DNS resolutions.
    ///
    /// We model the [`State::Recreating`] state differently from just removing the entry to allow packets
    /// to continue flowing to the Gateway while the DNS resource NAT is being recreated.
    /// In most cases, the DNS records will not change and as such, performing this will not interrupt the flow of packets.
    pub fn recreate(&mut self, domain: DomainName) {
        for state in self
            .inner
            .iter_mut()
            .filter_map(|((_, candidate), b)| (candidate == &domain).then_some(b))
        {
            let should_buffer = match state {
                State::Recreating { .. } | State::Pending { .. } => continue,
                State::Confirmed => false, // Don't buffer packets if already confirmed.
                State::Failed => true,     // No NAT yet, buffer packets until confirmed.
            };

            tracing::debug!(%domain, "Re-creating DNS resource NAT");
            *state = State::Recreating { should_buffer };
        }
    }

    /// Handles an outgoing packet for a DNS resource.
    ///
    /// If the DNS resource NAT is still being created, the packet gets buffered.
    /// Otherwise, it is returned again.
    pub fn handle_outgoing(
        &mut self,
        gid: GatewayId,
        domain: &DomainName,
        packet: IpPacket,
    ) -> Option<IpPacket> {
        if let Some(State::Pending {
            buffered_packets,
            should_buffer: true,
            ..
        }) = self.inner.get_mut(&(gid, domain.clone()))
        {
            buffered_packets.push(packet);
            return None;
        }

        Some(packet)
    }

    pub fn clear_by_gateway(&mut self, gid: &GatewayId) {
        self.inner.retain(|(gateway, _), _| gateway != gid);
    }

    pub fn clear_by_domain(&mut self, domain: &DomainName) {
        self.inner.retain(|(_, candidate), _| candidate != domain);
    }

    pub fn clear(&mut self) {
        self.inner.clear();
    }

    pub(crate) fn on_domain_status(
        &mut self,
        gid: GatewayId,
        res: p2p_control::dns_resource_nat::DomainStatus,
    ) -> impl IntoIterator<Item = IpPacket> {
        let Entry::Occupied(mut nat_entry) = self.inner.entry((gid, res.domain.clone())) else {
            tracing::debug!(%gid, domain = %res.domain, "No DNS resource NAT state, ignoring response");
            return into_iter(None);
        };

        let nat_state = nat_entry.get_mut();

        if res.status != p2p_control::dns_resource_nat::NatStatus::Active {
            tracing::debug!(%gid, domain = %res.domain, "DNS resource NAT is not active");
            nat_state.failed();
            return into_iter(None);
        }

        tracing::debug!(%gid, domain = %res.domain, num_buffered_packets = %nat_state.num_buffered_packets(), "DNS resource NAT is active");

        into_iter(Some(nat_state.confirm()))
    }
}

fn into_iter<T>(option: Option<T>) -> impl IntoIterator<Item = IpPacket>
where
    T: IntoIterator<Item = IpPacket>,
{
    option.into_iter().flatten()
}

enum State {
    Pending {
        sent_at: Instant,
        buffered_packets: UniquePacketBuffer,

        should_buffer: bool,
    },
    Recreating {
        should_buffer: bool,
    },
    Confirmed,
    Failed,
}

impl State {
    fn num_buffered_packets(&self) -> usize {
        match self {
            State::Pending {
                buffered_packets, ..
            } => buffered_packets.len(),
            State::Confirmed => 0,
            State::Recreating { .. } => 0,
            State::Failed => 0,
        }
    }

    fn confirm(&mut self) -> impl Iterator<Item = IpPacket> + use<> {
        let buffered_packets = match std::mem::replace(self, State::Confirmed) {
            State::Pending {
                buffered_packets, ..
            } => Some(buffered_packets.into_iter()),
            State::Recreating { .. } => None,
            State::Confirmed => None,
            State::Failed => None,
        };

        buffered_packets.into_iter().flatten()
    }

    fn failed(&mut self) {
        *self = State::Failed;
    }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use dns_types::DomainNameRef;
    use dns_types::prelude::*;

    use super::*;

    #[test]
    fn no_recreate_nat_for_failed_response() {
        let mut dns_resource_nat = DnsResourceNat::default();

        let intent = dns_resource_nat.update(
            EXAMPLE_COM.to_vec(),
            GID,
            RID,
            PROXY_IPS,
            VecDeque::default(),
            Instant::now(),
        );
        assert!(intent.is_some());

        dns_resource_nat.on_domain_status(
            GID,
            p2p_control::dns_resource_nat::DomainStatus {
                status: p2p_control::dns_resource_nat::NatStatus::Inactive,
                resource: RID,
                domain: EXAMPLE_COM.to_vec(),
            },
        );

        let intent = dns_resource_nat.update(
            EXAMPLE_COM.to_vec(),
            GID,
            RID,
            PROXY_IPS,
            VecDeque::default(),
            Instant::now(),
        );
        assert!(intent.is_none());
    }

    #[test]
    fn recreate_failed_nat() {
        let mut dns_resource_nat = DnsResourceNat::default();

        dns_resource_nat.update(
            EXAMPLE_COM.to_vec(),
            GID,
            RID,
            PROXY_IPS,
            VecDeque::default(),
            Instant::now(),
        );
        dns_resource_nat.on_domain_status(
            GID,
            p2p_control::dns_resource_nat::DomainStatus {
                status: p2p_control::dns_resource_nat::NatStatus::Inactive,
                resource: RID,
                domain: EXAMPLE_COM.to_vec(),
            },
        );

        dns_resource_nat.recreate(EXAMPLE_COM.to_vec());

        let intent = dns_resource_nat.update(
            EXAMPLE_COM.to_vec(),
            GID,
            RID,
            PROXY_IPS,
            VecDeque::default(),
            Instant::now(),
        );
        assert!(intent.is_some());

        // Should buffer packets if we are coming from `Failed`.
        let packet =
            ip_packet::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, vec![])
                .unwrap();

        let maybe_packet = dns_resource_nat.handle_outgoing(GID, &EXAMPLE_COM.to_vec(), packet);

        assert!(maybe_packet.is_none());
    }

    #[test]
    fn buffer_packets_until_nat_is_active() {
        let mut dns_resource_nat = DnsResourceNat::default();

        dns_resource_nat.update(
            EXAMPLE_COM.to_vec(),
            GID,
            RID,
            PROXY_IPS,
            VecDeque::default(),
            Instant::now(),
        );

        let packet =
            ip_packet::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, vec![])
                .unwrap();

        let maybe_packet =
            dns_resource_nat.handle_outgoing(GID, &EXAMPLE_COM.to_vec(), packet.clone());

        assert!(maybe_packet.is_none());

        let packets = dns_resource_nat.on_domain_status(
            GID,
            p2p_control::dns_resource_nat::DomainStatus {
                status: p2p_control::dns_resource_nat::NatStatus::Active,
                resource: RID,
                domain: EXAMPLE_COM.to_vec(),
            },
        );

        assert_eq!(packets.into_iter().collect::<Vec<_>>(), vec![packet]);
    }

    #[test]
    fn dont_buffer_packets_upon_recreate() {
        let mut dns_resource_nat = DnsResourceNat::default();

        dns_resource_nat.update(
            EXAMPLE_COM.to_vec(),
            GID,
            RID,
            PROXY_IPS,
            VecDeque::default(),
            Instant::now(),
        );
        dns_resource_nat.on_domain_status(
            GID,
            p2p_control::dns_resource_nat::DomainStatus {
                status: p2p_control::dns_resource_nat::NatStatus::Active,
                resource: RID,
                domain: EXAMPLE_COM.to_vec(),
            },
        );

        dns_resource_nat.recreate(EXAMPLE_COM.to_vec());
        dns_resource_nat.update(
            EXAMPLE_COM.to_vec(),
            GID,
            RID,
            PROXY_IPS,
            VecDeque::default(),
            Instant::now(),
        );

        let packet =
            ip_packet::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, vec![])
                .unwrap();

        let maybe_packet = dns_resource_nat.handle_outgoing(GID, &EXAMPLE_COM.to_vec(), packet);

        assert!(maybe_packet.is_some());
    }

    #[test]
    fn resend_intent_after_2_seconds() {
        let mut dns_resource_nat = DnsResourceNat::default();
        let mut now = Instant::now();

        let mut update_fn = |now| {
            dns_resource_nat.update(
                EXAMPLE_COM.to_vec(),
                GID,
                RID,
                PROXY_IPS,
                VecDeque::default(),
                now,
            )
        };

        assert!(update_fn(now).is_some());
        assert!(update_fn(now).is_none());

        now += Duration::from_secs(2);

        assert!(update_fn(now).is_some());
    }

    const EXAMPLE_COM: DomainNameRef =
        unsafe { DomainNameRef::from_octets_unchecked(b"\x08example\x03com\x00") };
    const GID: GatewayId = GatewayId::from_u128(1);
    const RID: ResourceId = ResourceId::from_u128(2);
    const PROXY_IPS: &[IpAddr] = &[
        IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)),
        IpAddr::V4(Ipv4Addr::new(127, 0, 0, 2)),
        IpAddr::V4(Ipv4Addr::new(127, 0, 0, 3)),
        IpAddr::V4(Ipv4Addr::new(127, 0, 0, 4)),
        IpAddr::V4(Ipv4Addr::new(127, 0, 0, 5)),
        IpAddr::V4(Ipv4Addr::new(127, 0, 0, 6)),
        IpAddr::V4(Ipv4Addr::new(127, 0, 0, 7)),
        IpAddr::V4(Ipv4Addr::new(127, 0, 0, 8)),
    ];
}
