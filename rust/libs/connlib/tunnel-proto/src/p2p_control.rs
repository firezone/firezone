//! Firezone's P2P control protocol between clients and gateways, and between clients.
//!
//! The protocol is event-based, i.e. does not have a notion of requests or responses.
//! It operates on top of IP, meaning delivery is not guaranteed.
//!
//! Unreliable, event-based protocols require application-level retransmissions.
//! When adding a new event type, it is therefore strongly recommended to make its semantics idempotent.
//!
//! The protocol has a fixed 8-byte header where the first byte is reserved for the event-type.
//! Usually, events will be grouped into a namespace.
//! These namespaces are purely conventional and not represented on the protocol level.

use ip_packet::{FzP2pEventType, IpPacket};

pub const ASSIGNED_IPS_EVENT: FzP2pEventType = FzP2pEventType::new(0);
pub const DOMAIN_STATUS_EVENT: FzP2pEventType = FzP2pEventType::new(1);
pub const GOODBYE_EVENT: FzP2pEventType = FzP2pEventType::new(2);
pub const NO_AUTHORIZATION_EVENT: FzP2pEventType = FzP2pEventType::new(3);

pub mod dns_resource_nat {
    use super::*;
    use anyhow::{Context as _, Result};
    use connlib_model::ResourceId;
    use dns_types::DomainName;
    use ip_packet::{FzP2pControlSlice, IpPacket};
    use std::net::IpAddr;

    /// Construct a new [`AssignedIps`] event.
    pub fn assigned_ips(
        resource: ResourceId,
        domain: DomainName,
        proxy_ips: Vec<IpAddr>,
    ) -> Result<IpPacket> {
        anyhow::ensure!(
            proxy_ips.len() == 4 || proxy_ips.len() == 8,
            "Expected 4 or 8 proxy IPs"
        );

        let payload = serde_json::to_vec(&AssignedIps {
            resource,
            domain,
            proxy_ips,
        })
        .context("Failed to serialize `AssignedIps` event")?;

        let ip_packet = ip_packet::make::fz_p2p_control(
            [ASSIGNED_IPS_EVENT.into_u8(), 0, 0, 0, 0, 0, 0, 0],
            &payload,
        )
        .context("Failed to create p2p control protocol packet")?;

        Ok(ip_packet)
    }

    /// Construct a new [`DomainStatus`] event.
    pub fn domain_status(
        resource: ResourceId,
        domain: DomainName,
        status: NatStatus,
    ) -> Result<IpPacket> {
        let payload = serde_json::to_vec(&DomainStatus {
            status,
            resource,
            domain,
        })
        .context("Failed to serialize `DomainStatus` event")?;

        let ip_packet = ip_packet::make::fz_p2p_control(
            [DOMAIN_STATUS_EVENT.into_u8(), 0, 0, 0, 0, 0, 0, 0],
            &payload,
        )
        .context("Failed to create p2p control protocol packet")?;

        Ok(ip_packet)
    }

    pub fn decode_assigned_ips(packet: FzP2pControlSlice) -> Result<AssignedIps> {
        anyhow::ensure!(
            packet.event_type() == ASSIGNED_IPS_EVENT,
            "Control protocol packet is not a `dns_resource_nat::AssignedIp`s event"
        );

        serde_json::from_slice::<AssignedIps>(packet.payload())
            .context("Failed to deserialize `dns_resource_nat::AssignedIps`")
    }

    pub fn decode_domain_status(packet: FzP2pControlSlice) -> Result<DomainStatus> {
        anyhow::ensure!(
            packet.event_type() == DOMAIN_STATUS_EVENT,
            "Control protocol packet is not a `dns_resource_nat::DomainStatus` event"
        );

        serde_json::from_slice::<DomainStatus>(packet.payload())
            .context("Failed to deserialize `dns_resource_nat::DomainStatus`")
    }

    #[derive(serde::Serialize, serde::Deserialize)]
    pub struct AssignedIps {
        pub resource: ResourceId,
        pub domain: DomainName,
        pub proxy_ips: Vec<IpAddr>,
    }

    #[derive(serde::Serialize, serde::Deserialize)]
    pub struct DomainStatus {
        pub resource: ResourceId,
        pub domain: DomainName,
        pub status: NatStatus,
    }

    #[derive(serde::Serialize, serde::Deserialize, PartialEq, Eq, Debug)]
    pub enum NatStatus {
        /// The NAT is active and traffic will be routed.
        Active,
        /// The NAT is inactive and traffic won't be routed.
        #[serde(other)] // For forwards-compatibility with future versions of this enum.
        Inactive,
    }

    #[cfg(test)]
    mod tests {

        use super::*;
        use std::net::{Ipv4Addr, Ipv6Addr};

        #[test]
        fn max_payload_length_assigned_ips() {
            let assigned_ips = AssignedIps {
                resource: ResourceId::from_u128(100),
                domain: longest_domain_possible(),
                proxy_ips: eight_proxy_ips(),
            };

            let serialized = serde_json::to_vec(&assigned_ips).unwrap();

            assert_eq!(serialized.len(), 402);
            assert!(serialized.len() <= ip_packet::MAX_IP_SIZE);
        }

        #[test]
        fn assigned_ips_serde_roundtrip() {
            let packet = assigned_ips(
                ResourceId::from_u128(101),
                domain("example.com"),
                eight_proxy_ips(),
            )
            .unwrap();

            let slice = packet.as_fz_p2p_control().unwrap();
            let assigned_ips = decode_assigned_ips(slice).unwrap();

            assert_eq!(assigned_ips.resource, ResourceId::from_u128(101));
            assert_eq!(assigned_ips.domain, domain("example.com"));
            assert_eq!(assigned_ips.proxy_ips, eight_proxy_ips())
        }

        #[test]
        fn domain_status_serde_roundtrip() {
            let packet = domain_status(
                ResourceId::from_u128(101),
                domain("example.com"),
                NatStatus::Active,
            )
            .unwrap();

            let slice = packet.as_fz_p2p_control().unwrap();
            let domain_status = decode_domain_status(slice).unwrap();

            assert_eq!(domain_status.resource, ResourceId::from_u128(101));
            assert_eq!(domain_status.domain, domain("example.com"));
            assert_eq!(domain_status.status, NatStatus::Active)
        }

        #[test]
        fn domain_status_ignored_unknown_nat_status() {
            let payload = r#"{"resource":"00000000-0000-0000-0000-000000000065","domain":"example.com","status":"what_is_this"}"#;
            let packet = ip_packet::make::fz_p2p_control(
                [DOMAIN_STATUS_EVENT.into_u8(), 0, 0, 0, 0, 0, 0, 0],
                payload.as_bytes(),
            )
            .expect("payload is less than max packet size");

            let slice = packet.as_fz_p2p_control().unwrap();
            let domain_status = decode_domain_status(slice).unwrap();

            assert_eq!(domain_status.resource, ResourceId::from_u128(101));
            assert_eq!(domain_status.domain, domain("example.com"));
            assert_eq!(domain_status.status, NatStatus::Inactive);
        }

        fn domain(d: &str) -> DomainName {
            d.parse().unwrap()
        }

        fn longest_domain_possible() -> DomainName {
            let label = "a".repeat(49);
            let domain =
                DomainName::vec_from_str(&format!("{label}.{label}.{label}.{label}.{label}.com"))
                    .unwrap();
            assert_eq!(domain.len(), dns_types::MAX_NAME_LEN);

            domain
        }

        fn eight_proxy_ips() -> Vec<IpAddr> {
            vec![
                IpAddr::V4(Ipv4Addr::LOCALHOST),
                IpAddr::V4(Ipv4Addr::LOCALHOST),
                IpAddr::V4(Ipv4Addr::LOCALHOST),
                IpAddr::V4(Ipv4Addr::LOCALHOST),
                IpAddr::V6(Ipv6Addr::LOCALHOST),
                IpAddr::V6(Ipv6Addr::LOCALHOST),
                IpAddr::V6(Ipv6Addr::LOCALHOST),
                IpAddr::V6(Ipv6Addr::LOCALHOST),
            ]
        }
    }
}

pub fn goodbye() -> IpPacket {
    ip_packet::make::fz_p2p_control([GOODBYE_EVENT.into_u8(), 0, 0, 0, 0, 0, 0, 0], &[])
        .expect("should always be able to make a `goodbye` packet")
}

pub mod no_authorization {
    use super::*;
    use anyhow::{Context as _, Result};
    use connlib_model::ResourceId;
    use ip_network::IpNetwork;
    use std::collections::BTreeMap;

    use crate::filter_engine::FilterEngine;
    use crate::messages::Filter;
    use crate::routing_table::{self, RoutingTable};
    use ip_packet::{FzP2pControlSlice, IpPacket};
    use std::net::IpAddr;

    /// Constructs an event for a packet whose destination has no active authorization on the receiver.
    ///
    /// The receiver may be a gateway or another client. The event carries the denied
    /// destination and protocol so the sender can resolve its own matching authorizations.
    /// The sender resolves the destination against its routes and requests fresh access
    /// for matching grants on the peer that sent the event. ICMP errors remain independent
    /// so rejected application traffic can stop while authorization is refreshed.
    pub fn event(dst: IpAddr, protocol: Protocol) -> Result<IpPacket> {
        let payload = serde_json::to_vec(&NoAuthorization { dst, protocol })
            .context("Failed to serialize `NoAuthorization` event")?;

        let ip_packet = ip_packet::make::fz_p2p_control(
            [NO_AUTHORIZATION_EVENT.into_u8(), 0, 0, 0, 0, 0, 0, 0],
            &payload,
        )
        .context("Failed to create p2p control protocol packet")?;

        Ok(ip_packet)
    }

    pub fn decode(packet: FzP2pControlSlice) -> Result<NoAuthorization> {
        anyhow::ensure!(
            packet.event_type() == NO_AUTHORIZATION_EVENT,
            "Control protocol packet is not an `NoAuthorization` event"
        );

        serde_json::from_slice::<NoAuthorization>(packet.payload())
            .context("Failed to deserialize `NoAuthorization`")
    }

    /// Limits traffic-triggered events to once every two seconds per authorization scope.
    #[derive(Default)]
    pub(crate) struct Sender {
        // Scope metadata survives authorization expiry so all addresses of a resource share a limit.
        scopes: RoutingTable<Scope>,
        last_sent_at: BTreeMap<Option<ResourceId>, std::time::Instant>,
    }

    #[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
    struct Scope {
        resource_id: ResourceId,
        filter: FilterEngine,
    }

    impl routing_table::RouteEntry for Scope {
        fn filter(&self) -> &FilterEngine {
            &self.filter
        }

        fn resource_id(&self) -> ResourceId {
            self.resource_id
        }
    }

    impl Sender {
        const THROTTLE: std::time::Duration = std::time::Duration::from_secs(2);

        pub(crate) fn register_scope(
            &mut self,
            resource_id: ResourceId,
            networks: impl IntoIterator<Item = IpNetwork>,
            filters: &[Filter],
        ) {
            self.scopes.remove_by_id(resource_id);
            let scope = Scope {
                resource_id,
                filter: FilterEngine::new(filters),
            };
            for network in networks {
                self.scopes.upsert(network, scope.clone());
            }
        }

        pub(crate) fn scope_for_packet(&mut self, packet: &IpPacket) -> Option<ResourceId> {
            let scope = self
                .scopes
                .matches(
                    packet.destination(),
                    packet.destination_protocol(),
                    routing_table::FilterMode::Apply,
                )?
                .first()?;

            Some(scope.resource_id)
        }

        pub(crate) fn for_packet(
            &mut self,
            packet: &IpPacket,
            now: std::time::Instant,
        ) -> Option<IpPacket> {
            let protocol = packet.destination_protocol().ok()?;
            let scope = self.scope_for_packet(packet);
            // Unknown destinations share a fallback limit rather than growing state per packet IP.
            if self
                .last_sent_at
                .get(&scope)
                .is_some_and(|sent_at| now.duration_since(*sent_at) < Self::THROTTLE)
            {
                return None;
            }

            let event = event(packet.destination(), protocol.into())
                .inspect_err(|e| tracing::trace!("Failed to create `NoAuthorization` event: {e:#}"))
                .ok()?;
            self.last_sent_at.insert(scope, now);

            Some(event)
        }
    }

    #[derive(serde::Serialize, serde::Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
    pub struct NoAuthorization {
        pub dst: IpAddr,
        pub protocol: Protocol,
    }

    #[derive(serde::Serialize, serde::Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
    #[serde(rename_all = "snake_case")]
    pub enum Protocol {
        Tcp { dst_port: u16 },
        Udp { dst_port: u16 },
        Icmp,
    }

    impl From<ip_packet::Protocol> for Protocol {
        fn from(p: ip_packet::Protocol) -> Self {
            match p {
                ip_packet::Protocol::Tcp(dst_port) => Protocol::Tcp { dst_port },
                ip_packet::Protocol::Udp(dst_port) => Protocol::Udp { dst_port },
                // The echo identifier is irrelevant for identifying the authorization.
                ip_packet::Protocol::IcmpEcho(_) => Protocol::Icmp,
            }
        }
    }

    impl From<Protocol> for ip_packet::Protocol {
        fn from(p: Protocol) -> Self {
            match p {
                Protocol::Tcp { dst_port } => ip_packet::Protocol::Tcp(dst_port),
                Protocol::Udp { dst_port } => ip_packet::Protocol::Udp(dst_port),
                Protocol::Icmp => ip_packet::Protocol::IcmpEcho(0),
            }
        }
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        use std::net::{Ipv4Addr, Ipv6Addr};

        #[test]
        fn rate_limits_rejections_per_cidr_resource() {
            let now = std::time::Instant::now();
            let mut sender = Sender::default();
            let resource = ResourceId::from_u128(1);
            sender.register_scope(resource, ["10.0.0.0/24".parse().unwrap()], &[]);
            sender.register_scope(
                ResourceId::from_u128(2),
                ["10.1.0.0/24".parse().unwrap()],
                &[],
            );
            let first = rejected_packet(Ipv4Addr::new(10, 0, 0, 1));
            let second = rejected_packet(Ipv4Addr::new(10, 0, 0, 2));

            assert!(sender.for_packet(&first, now).is_some());
            assert!(
                sender
                    .for_packet(&rejected_packet(Ipv4Addr::new(10, 1, 0, 1)), now)
                    .is_some()
            );
            sender.register_scope(resource, ["10.0.0.0/24".parse().unwrap()], &[]);
            for milliseconds in [0, 100, 1000, 1999] {
                let now = now + std::time::Duration::from_millis(milliseconds);
                assert!(sender.for_packet(&first, now).is_none());
                assert!(sender.for_packet(&second, now).is_none());
            }
            let event = sender.for_packet(&second, now + Sender::THROTTLE).unwrap();

            assert_eq!(
                decode(event.as_fz_p2p_control().unwrap()).unwrap().dst,
                second.destination()
            );
        }

        #[test]
        fn independently_limits_scopes_for_the_same_peer_address() {
            let now = std::time::Instant::now();
            let mut sender = Sender::default();
            let dst = Ipv4Addr::new(100, 64, 0, 2);
            sender.register_scope(
                ResourceId::from_u128(1),
                [dst.into()],
                &[Filter::Udp(crate::messages::PortRange::single(80))],
            );
            sender.register_scope(
                ResourceId::from_u128(2),
                [dst.into()],
                &[Filter::Udp(crate::messages::PortRange::single(443))],
            );
            let first =
                ip_packet::make::udp_packet(Ipv4Addr::new(100, 64, 0, 1), dst, 1234, 80, &[])
                    .unwrap();
            let second =
                ip_packet::make::udp_packet(Ipv4Addr::new(100, 64, 0, 1), dst, 1234, 443, &[])
                    .unwrap();

            assert!(sender.for_packet(&first, now).is_some());
            assert!(sender.for_packet(&second, now).is_some());
            assert!(sender.for_packet(&first, now).is_none());
            assert!(sender.for_packet(&second, now).is_none());
        }

        #[test]
        fn no_authorization_serde_roundtrip() {
            let packet = event(
                IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)),
                Protocol::Tcp { dst_port: 443 },
            )
            .unwrap();

            let slice = packet.as_fz_p2p_control().unwrap();
            let no_authorization = decode(slice).unwrap();

            assert_eq!(no_authorization.dst, IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)));
            assert_eq!(no_authorization.protocol, Protocol::Tcp { dst_port: 443 });
        }

        #[test]
        fn no_authorization_serde_roundtrip_icmp_ipv6() {
            let packet = event(IpAddr::V6(Ipv6Addr::LOCALHOST), Protocol::Icmp).unwrap();

            let slice = packet.as_fz_p2p_control().unwrap();
            let no_authorization = decode(slice).unwrap();

            assert_eq!(no_authorization.dst, IpAddr::V6(Ipv6Addr::LOCALHOST));
            assert_eq!(no_authorization.protocol, Protocol::Icmp);
        }
        fn rejected_packet(dst: Ipv4Addr) -> IpPacket {
            ip_packet::make::udp_packet(Ipv4Addr::LOCALHOST, dst, 1234, 443, &[]).unwrap()
        }
    }
}
