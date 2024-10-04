//! Firezone's P2P control protocol between clients and gateways.

#[cfg_attr(not(test), expect(dead_code, reason = "Will be used soon."))]
pub mod setup_dns_resource_nat {
    use anyhow::{Context, Result};
    use connlib_model::{DomainName, ResourceId};
    use ip_packet::{FzP2pControlSlice, IpPacket};
    use std::net::IpAddr;

    pub const REQ_CODE: u8 = 0;
    pub const RES_CODE: u8 = 1;

    pub fn request(resource: ResourceId, domain: DomainName, proxy_ips: Vec<IpAddr>) -> IpPacket {
        debug_assert_eq!(proxy_ips.len(), 8);

        let payload = serde_json::to_vec(&Request {
            resource,
            domain,
            proxy_ips,
        })
        .unwrap();

        ip_packet::make::fz_p2p_control([REQ_CODE, 0, 0, 0, 0, 0, 0, 0], &payload)
            .expect("with only 8 proxy IPs, payload should be less than max packet size")
    }

    pub fn response(resource: ResourceId, domain: DomainName, code: u16) -> IpPacket {
        let payload = serde_json::to_vec(&Response {
            code,
            resource,
            domain,
        })
        .unwrap();

        ip_packet::make::fz_p2p_control([RES_CODE, 0, 0, 0, 0, 0, 0, 0], &payload)
            .expect("payload is less than max packet size")
    }

    pub fn decode_request(packet: FzP2pControlSlice) -> Result<Request> {
        anyhow::ensure!(
            packet.message_type() == REQ_CODE,
            "Control protocol packet is not a setup-dns-resource-nat request"
        );

        serde_json::from_slice::<Request>(packet.payload())
            .context("Failed to deserialize `setup_dns_resource_nat::Request`")
    }

    pub fn decode_response(packet: FzP2pControlSlice) -> Result<Response> {
        anyhow::ensure!(
            packet.message_type() == RES_CODE,
            "Control protocol packet is not a setup-dns-resource-nat request"
        );

        serde_json::from_slice::<Response>(packet.payload())
            .context("Failed to deserialize `setup_dns_resource_nat::Response`")
    }

    #[derive(serde::Serialize, serde::Deserialize)]
    pub struct Request {
        pub resource: ResourceId,
        pub domain: DomainName,
        pub proxy_ips: Vec<IpAddr>,
    }

    #[derive(serde::Serialize, serde::Deserialize)]
    pub struct Response {
        pub resource: ResourceId,
        pub domain: DomainName,
        pub code: u16, // Loosely follows the semantics of HTTP.
    }

    #[cfg(test)]
    mod tests {
        use domain::base::Name;

        use super::*;
        use std::net::{Ipv4Addr, Ipv6Addr};

        #[test]
        fn max_payload_length_request() {
            let request = Request {
                resource: ResourceId::from_u128(100),
                domain: longest_domain_possible(),
                proxy_ips: vec![
                    IpAddr::V4(Ipv4Addr::LOCALHOST),
                    IpAddr::V4(Ipv4Addr::LOCALHOST),
                    IpAddr::V4(Ipv4Addr::LOCALHOST),
                    IpAddr::V4(Ipv4Addr::LOCALHOST),
                    IpAddr::V6(Ipv6Addr::LOCALHOST),
                    IpAddr::V6(Ipv6Addr::LOCALHOST),
                    IpAddr::V6(Ipv6Addr::LOCALHOST),
                    IpAddr::V6(Ipv6Addr::LOCALHOST),
                ],
            };

            let serialized = serde_json::to_vec(&request).unwrap();

            assert_eq!(serialized.len(), 402);
            assert!(serialized.len() <= ip_packet::PACKET_SIZE);
        }

        fn longest_domain_possible() -> DomainName {
            let label = "a".repeat(49);
            let domain =
                DomainName::vec_from_str(&format!("{label}.{label}.{label}.{label}.{label}.com"))
                    .unwrap();
            assert_eq!(domain.len(), Name::MAX_LEN);

            domain
        }

        #[test]
        fn request_serde_roundtrip() {
            let packet = request(
                ResourceId::from_u128(101),
                domain("example.com"),
                vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
            );

            let slice = packet.as_fz_p2p_control().unwrap();
            let request = decode_request(slice).unwrap();

            assert_eq!(request.resource, ResourceId::from_u128(101));
            assert_eq!(request.domain, domain("example.com"));
            assert_eq!(request.proxy_ips, vec![IpAddr::V4(Ipv4Addr::LOCALHOST)])
        }

        #[test]
        fn response_serde_roundtrip() {
            let packet = response(ResourceId::from_u128(101), domain("example.com"), 200);

            let slice = packet.as_fz_p2p_control().unwrap();
            let request = decode_response(slice).unwrap();

            assert_eq!(request.resource, ResourceId::from_u128(101));
            assert_eq!(request.domain, domain("example.com"));
            assert_eq!(request.code, 200)
        }

        fn domain(d: &str) -> DomainName {
            d.parse().unwrap()
        }
    }
}
