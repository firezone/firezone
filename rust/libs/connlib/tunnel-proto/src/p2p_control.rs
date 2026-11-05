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
    use crate::client::{IPV4_RESOURCES, IPV6_RESOURCES};
    use anyhow::{Context as _, Result};
    use connlib_model::{IpStack, ResourceId};
    use dns_types::DomainName;
    use ip_packet::{FzP2pControlSlice, IpPacket};
    use serde::de::{Error as _, SeqAccess, Visitor};
    use std::fmt;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    /// Construct a new [`AssignedIps`] event.
    pub fn assigned_ips(
        resource: ResourceId,
        domain: DomainName,
        proxy_ips: ProxyIps,
    ) -> Result<IpPacket> {
        let payload = serde_json::to_vec(&AssignedIps {
            resource,
            domain,
            proxy_ips: Some(proxy_ips),
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

    #[serde_with::serde_as]
    #[derive(serde::Serialize, serde::Deserialize)]
    pub struct AssignedIps {
        pub resource: ResourceId,
        pub domain: DomainName,
        /// `None` if the proxy IPs are invalid.
        #[serde_as(as = "serde_with::DefaultOnError")]
        pub proxy_ips: Option<ProxyIps>,
    }

    /// The proxy IPs a Client assigns to a domain.
    ///
    /// Holds 4 addresses from [`IPV4_RESOURCES`] and / or 4 addresses from [`IPV6_RESOURCES`].
    /// On the wire, this is a list of all addresses.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
    pub struct ProxyIps {
        ipv4: Option<[Ipv4Addr; 4]>,
        ipv6: Option<[Ipv6Addr; 4]>,
    }

    impl ProxyIps {
        /// Creates dual-stack proxy IPs.
        ///
        /// # Errors
        ///
        /// Fails if an address is not within [`IPV4_RESOURCES`] or [`IPV6_RESOURCES`].
        pub fn new(mut ipv4: [Ipv4Addr; 4], mut ipv6: [Ipv6Addr; 4]) -> Result<Self> {
            ipv4.sort();
            ipv6.sort();

            let proxy_ips = Self {
                ipv4: Some(ipv4),
                ipv6: Some(ipv6),
            }
            .ensure_within_resource_ranges()?;

            Ok(proxy_ips)
        }

        /// Returns only the proxy IPs of the IP versions that `ip_stack` supports.
        pub fn for_stack(self, ip_stack: IpStack) -> Self {
            Self {
                ipv4: self.ipv4.filter(|_| ip_stack.supports_ipv4()),
                ipv6: self.ipv6.filter(|_| ip_stack.supports_ipv6()),
            }
        }

        /// Returns all proxy IPs, IPv4 first.
        pub fn iter(&self) -> impl Iterator<Item = IpAddr> + use<> {
            let ipv4 = self.ipv4.into_iter().flatten().map(IpAddr::V4);
            let ipv6 = self.ipv6.into_iter().flatten().map(IpAddr::V6);

            ipv4.chain(ipv6)
        }

        fn ensure_within_resource_ranges(self) -> Result<Self> {
            let outside = self.iter().find(|ip| match ip {
                IpAddr::V4(ip) => !IPV4_RESOURCES.contains(*ip),
                IpAddr::V6(ip) => !IPV6_RESOURCES.contains(*ip),
            });

            if let Some(ip) = outside {
                anyhow::bail!("Proxy IP {ip} is not within {IPV4_RESOURCES} or {IPV6_RESOURCES}")
            }

            Ok(self)
        }
    }

    #[cfg(test)]
    impl ProxyIps {
        pub(crate) fn for_test() -> Self {
            let ipv4 = [1, 2, 3, 4].map(|i| Ipv4Addr::new(100, 96, 0, i));
            let ipv6 =
                [0, 1, 2, 3].map(|i| Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0, 0, 0, i));

            Self::new(ipv4, ipv6).expect("addresses are within the resource ranges")
        }
    }

    impl serde::Serialize for ProxyIps {
        fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
        where
            S: serde::Serializer,
        {
            serializer.collect_seq(self.iter())
        }
    }

    impl<'de> serde::Deserialize<'de> for ProxyIps {
        fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
        where
            D: serde::Deserializer<'de>,
        {
            deserializer.deserialize_seq(ProxyIpsVisitor)
        }
    }

    struct ProxyIpsVisitor;

    impl<'de> Visitor<'de> for ProxyIpsVisitor {
        type Value = ProxyIps;

        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
            f.write_str("4 IPv4 and / or 4 IPv6 proxy IPs")
        }

        fn visit_seq<A>(self, mut seq: A) -> Result<ProxyIps, A::Error>
        where
            A: SeqAccess<'de>,
        {
            let mut ipv4 = [Ipv4Addr::UNSPECIFIED; 4];
            let mut ipv6 = [Ipv6Addr::UNSPECIFIED; 4];
            let mut num_ipv4 = 0;
            let mut num_ipv6 = 0;

            while let Some(ip) = seq.next_element::<IpAddr>()? {
                match ip {
                    IpAddr::V4(ip) => {
                        *ipv4
                            .get_mut(num_ipv4)
                            .ok_or_else(|| A::Error::custom("More than 4 IPv4 proxy IPs"))? = ip;
                        num_ipv4 += 1;
                    }
                    IpAddr::V6(ip) => {
                        *ipv6
                            .get_mut(num_ipv6)
                            .ok_or_else(|| A::Error::custom("More than 4 IPv6 proxy IPs"))? = ip;
                        num_ipv6 += 1;
                    }
                }
            }

            let ipv4 = match num_ipv4 {
                0 => None,
                4 => {
                    ipv4.sort();
                    Some(ipv4)
                }
                n => return Err(A::Error::invalid_length(n, &"0 or 4 IPv4 proxy IPs")),
            };
            let ipv6 = match num_ipv6 {
                0 => None,
                4 => {
                    ipv6.sort();
                    Some(ipv6)
                }
                n => return Err(A::Error::invalid_length(n, &"0 or 4 IPv6 proxy IPs")),
            };

            if ipv4.is_none() && ipv6.is_none() {
                return Err(A::Error::invalid_length(0, &self));
            }

            let proxy_ips = ProxyIps { ipv4, ipv6 }
                .ensure_within_resource_ranges()
                .map_err(A::Error::custom)?;

            Ok(proxy_ips)
        }
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
        /// The Gateway removed the NAT to make space for other domains.
        Evicted,
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
                proxy_ips: Some(ProxyIps {
                    ipv4: Some([Ipv4Addr::LOCALHOST; 4]),
                    ipv6: Some([Ipv6Addr::LOCALHOST; 4]),
                }),
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
                ProxyIps::for_test(),
            )
            .unwrap();

            let slice = packet.as_fz_p2p_control().unwrap();
            let assigned_ips = decode_assigned_ips(slice).unwrap();

            assert_eq!(assigned_ips.resource, ResourceId::from_u128(101));
            assert_eq!(assigned_ips.domain, domain("example.com"));
            assert_eq!(assigned_ips.proxy_ips, Some(ProxyIps::for_test()))
        }

        #[test]
        fn proxy_ips_accepts_4_ips_per_ip_version() {
            for ips in [ipv4(4), ipv6(4), [ipv4(4), ipv6(4)].concat()] {
                let proxy_ips = serde_json::from_value::<ProxyIps>(serde_json::json!(ips)).unwrap();

                assert_eq!(proxy_ips.iter().collect::<Vec<_>>(), ips);
            }

            let unordered = [ipv6(4), ipv4(4)]
                .concat()
                .into_iter()
                .rev()
                .collect::<Vec<_>>();
            let proxy_ips =
                serde_json::from_value::<ProxyIps>(serde_json::json!(unordered)).unwrap();

            assert_eq!(
                proxy_ips.iter().collect::<Vec<_>>(),
                [ipv4(4), ipv6(4)].concat()
            );
        }

        #[test]
        fn proxy_ips_rejects_other_number_of_ips() {
            for ips in [
                ipv4(3),
                ipv4(5),
                ipv6(5),
                [ipv4(4), ipv6(3)].concat(),
                vec![],
            ] {
                let result = serde_json::from_value::<ProxyIps>(serde_json::json!(ips));

                assert!(result.is_err(), "{ips:?} should be rejected");
            }
        }

        #[test]
        fn proxy_ips_rejects_ips_outside_reserved_ranges() {
            let bad_ips = [
                "1.1.1.1",              // Public internet.
                "100.64.0.1",           // CG-NAT but reserved for Client tunnel IPs.
                "2606:4700:4700::1111", // Public internet.
                "fd00:2021:1111::1",    // Reserved for Client tunnel IPs.
            ];

            for bad_ip in bad_ips {
                let bad_ip = bad_ip.parse::<IpAddr>().unwrap();
                let mut ips = [ipv4(4), ipv6(4)].concat();
                let i = ips
                    .iter()
                    .position(|ip| ip.is_ipv4() == bad_ip.is_ipv4())
                    .unwrap();
                ips[i] = bad_ip;

                let result = serde_json::from_value::<ProxyIps>(serde_json::json!(ips));

                assert!(result.is_err(), "{bad_ip} should be rejected as proxy IP");
            }

            assert!(ProxyIps::new([Ipv4Addr::LOCALHOST; 4], [Ipv6Addr::LOCALHOST; 4]).is_err());
        }

        #[test]
        fn assigned_ips_decodes_event_with_invalid_proxy_ips() {
            let payload = serde_json::json!({
                "resource": ResourceId::from_u128(101),
                "domain": "example.com",
                "proxy_ips": ipv4(3),
            });
            let packet = ip_packet::make::fz_p2p_control(
                [ASSIGNED_IPS_EVENT.into_u8(), 0, 0, 0, 0, 0, 0, 0],
                &serde_json::to_vec(&payload).unwrap(),
            )
            .unwrap();
            let slice = packet.as_fz_p2p_control().unwrap();

            let assigned_ips = decode_assigned_ips(slice).unwrap();

            assert_eq!(assigned_ips.resource, ResourceId::from_u128(101));
            assert_eq!(assigned_ips.domain, domain("example.com"));
            assert_eq!(assigned_ips.proxy_ips, None);
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

        fn ipv4(n: u8) -> Vec<IpAddr> {
            (1..=n)
                .map(|i| IpAddr::from(Ipv4Addr::new(100, 96, 0, i)))
                .collect()
        }

        fn ipv6(n: u16) -> Vec<IpAddr> {
            (0..n)
                .map(|i| IpAddr::from(Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0, 0, 0, i)))
                .collect()
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
    use ip_packet::{FzP2pControlSlice, IpPacket};
    use std::net::IpAddr;

    /// Constructs an event for a packet rejected by the receiver's access policy.
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
    }
}
