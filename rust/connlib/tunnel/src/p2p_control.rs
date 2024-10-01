//! Firezone's P2P control protocol between clients and gateways.

pub mod setup_dns_resource_nat {
    use anyhow::{Context, Result};
    use connlib_model::{DomainName, ResourceId};
    use ip_packet::{FzP2pControlSlice, IpPacket};
    use std::net::IpAddr;

    pub const REQ_CODE: u8 = 0;
    pub const RES_CODE: u8 = 1;

    pub fn request(resource: ResourceId, domain: DomainName, proxy_ips: Vec<IpAddr>) -> IpPacket {
        let payload = serde_json::to_vec(&Request {
            resource,
            domain,
            proxy_ips,
        })
        .unwrap();

        ip_packet::make::fz_p2p_control([REQ_CODE, 0, 0, 0, 0, 0, 0, 0], &payload)
    }

    pub fn response(resource: ResourceId, domain: DomainName, code: u16) -> IpPacket {
        let payload = serde_json::to_vec(&Response {
            code,
            resource,
            domain,
        })
        .unwrap();

        ip_packet::make::fz_p2p_control([RES_CODE, 0, 0, 0, 0, 0, 0, 0], &payload)
    }

    pub fn decode_request(packet: FzP2pControlSlice) -> Result<Request> {
        serde_json::from_slice::<Request>(packet.payload())
            .context("Failed to deserialize `setup_dns_resource_nat::Request`")
    }

    pub fn decode_response(packet: FzP2pControlSlice) -> Result<Response> {
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
}
