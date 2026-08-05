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
use crate::transition::{DnsQuery, DnsTransport, IpFamily, Transition};

#[derive(Clone)]
pub(super) struct DnsQueryTarget {
    client_id: ClientId,
    dns_server: dns::Upstream,
    name: DnsNameSpec,
}

struct KnownPtrTarget {
    record_domain: DomainName,
    family: IpFamily,
    address_index: u32,
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

pub(super) fn generate(
    g: &mut Generator,
    target: DnsQueryTarget,
    state: &ReferenceState,
) -> Transition {
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
    let known_ptr_target = (r_type == RecordType::PTR)
        .then(|| arb_known_ptr_target(g, state, target.client_id))
        .flatten();

    if let Some(KnownPtrTarget {
        record_domain,
        family,
        address_index,
    }) = known_ptr_target
    {
        return Transition::SendDnsResourcePtrQuery {
            client_id: target.client_id,
            record_domain,
            family,
            address_index,
            query_id: arb_dns_query_id(g),
            dns_server: target.dns_server,
            transport: arb_dns_transport(g),
        };
    }

    let domain = if r_type == RecordType::PTR {
        DomainName::reverse_from_addr(arb_unassigned_ptr_query_ip(g))
            .expect("reverse DNS names always fit")
    } else {
        domain
    };

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

/// Sends arbitrary bytes to a stub resolver instead of a well-formed query.
///
/// Which byte patterns reach which of the structural checks in `dns_types::Query::parse`
/// is left to the fuzzer; enumerating them here would only cover the ways we thought of.
pub(super) fn generate_malformed(g: &mut Generator, target: DnsQueryTarget) -> Transition {
    let payload = g.bytes(0, 64);

    // Bytes that happen to parse are a valid query like any other, which the client
    // answers. Modelling that is `SendDnsQuery`'s job, so leave those to it.
    if dns_types::Query::parse(&payload).is_ok() {
        return Transition::Idle;
    }

    Transition::SendMalformedDnsQuery {
        client_id: target.client_id,
        payload,
        dns_server: target.dns_server,
        local_port: g.u16(),
    }
}

fn arb_known_ptr_target(
    g: &mut Generator,
    state: &ReferenceState,
    client_id: ClientId,
) -> Option<KnownPtrTarget> {
    let client = state.clients[&client_id].inner();
    let resolved_v4_domains = client
        .resolved_v4_domains()
        .into_iter()
        .map(|(domain, _)| domain)
        .collect::<Vec<_>>();
    let resolved_v6_domains = client
        .resolved_v6_domains()
        .into_iter()
        .map(|(domain, _)| domain)
        .collect::<Vec<_>>();

    if (resolved_v4_domains.is_empty() && resolved_v6_domains.is_empty()) || g.bool() {
        return None;
    }

    let select_ipv4 = g.bool();
    let (domains, family) =
        if (select_ipv4 && !resolved_v4_domains.is_empty()) || resolved_v6_domains.is_empty() {
            (resolved_v4_domains, IpFamily::Ipv4)
        } else {
            (resolved_v6_domains, IpFamily::Ipv6)
        };
    let address_index = g.u32();
    let record_domain = domains[address_index as usize % domains.len()].clone();

    Some(KnownPtrTarget {
        record_domain,
        family,
        address_index,
    })
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

fn arb_unassigned_ptr_query_ip(g: &mut Generator) -> IpAddr {
    use tunnel_proto::{IPV4_RESOURCES, IPV6_RESOURCES};

    match arb_ptr_query_ip(g) {
        IpAddr::V4(ip) if IPV4_RESOURCES.contains(ip) => {
            IpAddr::V4(Ipv4Addr::from(u32::from(ip) ^ (1u32 << 31)))
        }
        IpAddr::V6(ip) if IPV6_RESOURCES.contains(ip) => {
            IpAddr::V6(Ipv6Addr::from(u128::from(ip) ^ (1u128 << 127)))
        }
        IpAddr::V4(ip) => IpAddr::V4(ip),
        IpAddr::V6(ip) => IpAddr::V6(ip),
    }
}

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
