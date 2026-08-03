//! Firezone's P2P control protocol between clients and gateways.
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
pub const AUTHORIZATION_REQUIRED_EVENT: FzP2pEventType = FzP2pEventType::new(3);

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

pub mod authorization_required {
    use super::*;
    use anyhow::{Context as _, Result};
    use ip_packet::{FzP2pControlSlice, IpPacket};
    use std::net::IpAddr;

    /// Construct a new [`AuthorizationRequired`] event.
    ///
    /// The Gateway sends this event to the Client when it receives a packet for a destination
    /// that none of the Client's active authorizations cover, e.g. because it expired.
    /// Upon receiving the event, the Client discards its local authorization state for the
    /// corresponding resource so that the next packet requests a new authorization.
    ///
    /// The event names the denied flow's destination and protocol instead of a resource ID:
    /// once an authorization expired or was revoked, the Gateway no longer knows which
    /// resource the destination belonged to. The Client resolves the destination against its
    /// own routing table, which is authoritative for which authorization produced the packet.
    pub fn event(dst: IpAddr, protocol: Protocol) -> Result<IpPacket> {
        let payload = serde_json::to_vec(&AuthorizationRequired { dst, protocol })
            .context("Failed to serialize `AuthorizationRequired` event")?;

        let ip_packet = ip_packet::make::fz_p2p_control(
            [AUTHORIZATION_REQUIRED_EVENT.into_u8(), 0, 0, 0, 0, 0, 0, 0],
            &payload,
        )
        .context("Failed to create p2p control protocol packet")?;

        Ok(ip_packet)
    }

    pub fn decode(packet: FzP2pControlSlice) -> Result<AuthorizationRequired> {
        anyhow::ensure!(
            packet.event_type() == AUTHORIZATION_REQUIRED_EVENT,
            "Control protocol packet is not an `AuthorizationRequired` event"
        );

        serde_json::from_slice::<AuthorizationRequired>(packet.payload())
            .context("Failed to deserialize `AuthorizationRequired`")
    }

    #[derive(serde::Serialize, serde::Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
    pub struct AuthorizationRequired {
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
        fn authorization_required_serde_roundtrip() {
            let packet = event(
                IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)),
                Protocol::Tcp { dst_port: 443 },
            )
            .unwrap();

            let slice = packet.as_fz_p2p_control().unwrap();
            let authorization_required = decode(slice).unwrap();

            assert_eq!(
                authorization_required.dst,
                IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1))
            );
            assert_eq!(
                authorization_required.protocol,
                Protocol::Tcp { dst_port: 443 }
            );
        }

        #[test]
        fn authorization_required_serde_roundtrip_icmp_ipv6() {
            let packet = event(IpAddr::V6(Ipv6Addr::LOCALHOST), Protocol::Icmp).unwrap();

            let slice = packet.as_fz_p2p_control().unwrap();
            let authorization_required = decode(slice).unwrap();

            assert_eq!(authorization_required.dst, IpAddr::V6(Ipv6Addr::LOCALHOST));
            assert_eq!(authorization_required.protocol, Protocol::Icmp);
        }
    }
}
