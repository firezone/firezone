use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    time::Instant,
};

use connlib_model::ClientId;
use dns_types::{DomainName, RecordType};
use tunnel_proto::dns;

use super::context::Generator;
use super::packets::{host_in_v4, host_in_v6};
use crate::reference::ReferenceState;
use crate::transition::{DnsQuery, DnsTransport, Transition};

#[derive(Clone)]
pub(super) struct DnsQueryTarget {
    client_id: ClientId,
    dns_server: dns::Upstream,
    name: DnsNameSpec,
}

#[derive(Clone)]
enum DnsNameSpec {
    Concrete {
        domain: DomainName,
        rtypes: Vec<RecordType>,
    },
    Wildcard {
        base: String,
    },
    KnownDevice {
        base: String,
        labels: Vec<String>,
    },
    UnknownDevice {
        base: String,
    },
}

pub(super) fn targets(state: &ReferenceState, now: Instant) -> Vec<DnsQueryTarget> {
    let servers = state.reachable_dns_servers();
    let labels = state.portal.device_labels();

    state
        .all_domains(now)
        .into_iter()
        .flat_map(|(client_id, domain, rtypes)| {
            servers
                .iter()
                .filter(move |(id, _)| *id == client_id)
                .map(move |(_, dns_server)| DnsQueryTarget {
                    client_id,
                    dns_server: dns_server.clone(),
                    name: DnsNameSpec::Concrete {
                        domain: domain.clone(),
                        rtypes: rtypes.clone(),
                    },
                })
        })
        .chain(
            state
                .wildcard_dns_resources()
                .into_iter()
                .flat_map(|(client_id, resource)| {
                    servers.iter().filter(move |(id, _)| *id == client_id).map(
                        move |(_, dns_server)| DnsQueryTarget {
                            client_id,
                            dns_server: dns_server.clone(),
                            name: DnsNameSpec::Wildcard {
                                base: resource.address.trim_start_matches("*.").to_owned(),
                            },
                        },
                    )
                }),
        )
        .chain(state.device_pool_query_targets().into_iter().flat_map(
            |(client_id, resource, dns_server)| {
                let base = resource.address.trim_start_matches("*.").to_owned();
                [
                    (!labels.is_empty()).then(|| DnsQueryTarget {
                        client_id,
                        dns_server: dns_server.clone(),
                        name: DnsNameSpec::KnownDevice {
                            base: base.clone(),
                            labels: labels.clone(),
                        },
                    }),
                    Some(DnsQueryTarget {
                        client_id,
                        dns_server,
                        name: DnsNameSpec::UnknownDevice { base },
                    }),
                ]
                .into_iter()
                .flatten()
            },
        ))
        .collect::<Vec<_>>()
}

pub(super) fn generate(g: &mut Generator, target: DnsQueryTarget) -> Transition {
    let (domain, rtypes) = match target.name {
        DnsNameSpec::Concrete { domain, rtypes } => (domain, rtypes),
        DnsNameSpec::Wildcard { base } => {
            let domain = format!("{}.{}", g.lower_ascii(3, 6), base)
                .parse::<DomainName>()
                .unwrap();
            let rtypes = if g.bool() {
                vec![RecordType::A]
            } else {
                vec![RecordType::AAAA]
            };
            (domain, rtypes)
        }
        DnsNameSpec::KnownDevice { base, labels } => {
            let label = &labels[g.choose_index(labels.len())];
            (
                format!("{label}.{base}").parse::<DomainName>().unwrap(),
                vec![RecordType::A],
            )
        }
        DnsNameSpec::UnknownDevice { base } => (
            format!("{}.{}", g.lower_ascii(3, 6), base)
                .parse::<DomainName>()
                .unwrap(),
            vec![RecordType::A],
        ),
    };

    let r_type = arb_maybe_available_response_rtype(g, &rtypes);
    let domain = matches!(r_type, RecordType::PTR)
        .then(|| DomainName::reverse_from_addr(arb_ptr_query_ip(g)).unwrap())
        .unwrap_or(domain);

    Transition::SendDnsQuery {
        client_id: target.client_id,
        query: DnsQuery {
            domain,
            r_type,
            query_id: arb_dns_query_id(g),
            dns_server: target.dns_server,
            transport: arb_dns_transport(g),
        },
    }
}

fn arb_dns_transport(g: &mut Generator) -> DnsTransport {
    if g.bool() {
        DnsTransport::Udp {
            local_port: g.u16(),
        }
    } else {
        DnsTransport::Tcp
    }
}

fn arb_dns_query_id(g: &mut Generator) -> u16 {
    if g.bool() { g.u16() } else { 33333 }
}

/// If the domain has an A/AAAA record, pick from {PTR, MX, A, AAAA};
/// otherwise pick from the available record types.
fn arb_maybe_available_response_rtype(g: &mut Generator, available: &[RecordType]) -> RecordType {
    if available.contains(&RecordType::A) || available.contains(&RecordType::AAAA) {
        // A/AAAA are weighted up: they are the only types that resolve DNS
        // resources to (proxy) IPs and thereby feed the packet / NAT paths,
        // while PTR and MX only exercise the negative answers.
        let choices = [
            RecordType::A,
            RecordType::A,
            RecordType::AAAA,
            RecordType::AAAA,
            RecordType::PTR,
            RecordType::MX,
        ];
        choices[g.choose_index(choices.len())]
    } else if available.is_empty() {
        // No records to choose from; default to A. `all_domains` normally filters
        // out empty-rtype domains, so this only keeps the helper total.
        RecordType::A
    } else {
        available[g.choose_index(available.len())]
    }
}

/// Generate a PTR target inside a resource range or anywhere in the IP space.
fn arb_ptr_query_ip(g: &mut Generator) -> IpAddr {
    use tunnel_proto::{IPV4_RESOURCES, IPV6_RESOURCES};
    match g.choose_index(3) {
        0 => IpAddr::V4(host_in_v4(g, IPV4_RESOURCES)),
        1 => IpAddr::V6(host_in_v6(g, IPV6_RESOURCES)),
        _ => {
            if g.bool() {
                IpAddr::V4(Ipv4Addr::from(g.u32()))
            } else {
                let hi = (g.u64() as u128) << 64;
                let lo = g.u64() as u128;
                IpAddr::V6(Ipv6Addr::from(hi | lo))
            }
        }
    }
}
