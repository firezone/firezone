use super::{
    dns_records::DnsRecords,
    sim_client::{RefClient, SimClient},
    sim_gateway::SimGateway,
    transition::{Destination, ReplyTo},
};
use connlib_model::GatewayId;
use ip_packet::IpPacket;
use itertools::Itertools;
use std::{
    collections::{hash_map::Entry, BTreeMap, HashMap, VecDeque},
    hash::Hash,
    marker::PhantomData,
    net::IpAddr,
    sync::atomic::{AtomicBool, Ordering},
};
use tracing::{Level, Span, Subscriber};
use tracing_subscriber::Layer;

/// Asserts the following properties for all ICMP handshakes:
/// 1. An ICMP request on the client MUST result in an ICMP response using the same sequence, identifier and flipped src & dst IP.
/// 2. An ICMP request on the gateway MUST target the intended resource:
///     - For CIDR resources, that is the actual CIDR resource IP.
///     - For DNS resources, the IP must match one of the resolved IPs for the domain.
/// 3. For DNS resources, the mapping of proxy IP to actual resource IP must be stable.
pub(crate) fn assert_icmp_packets_properties(
    ref_client: &RefClient,
    sim_client: &SimClient,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
    global_dns_records: &DnsRecords,
) {
    let received_icmp_requests = sim_gateways
        .iter()
        .map(|(g, s)| (*g, &s.received_icmp_requests))
        .collect();

    assert_packets_properties(
        ref_client,
        &sim_client.sent_icmp_requests,
        &received_icmp_requests,
        &ref_client.expected_icmp_handshakes,
        &sim_client.received_icmp_replies,
        "ICMP",
        global_dns_records,
        |seq, identifier| tracing::info_span!(target: "assertions", "ICMP", ?seq, ?identifier),
    );
}

/// Asserts the following properties for all UDP handshakes:
/// 1. An UDP request on the client MUST result in an UDP response using the flipped src & dst IP and sport and dport.
/// 2. An UDP request on the gateway MUST target the intended resource:
///     - For CIDR resources, that is the actual CIDR resource IP.
///     - For DNS resources, the IP must match one of the resolved IPs for the domain.
/// 3. For DNS resources, the mapping of proxy IP to actual resource IP must be stable.
pub(crate) fn assert_udp_packets_properties(
    ref_client: &RefClient,
    sim_client: &SimClient,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
    global_dns_records: &DnsRecords,
) {
    let received_udp_requests = sim_gateways
        .iter()
        .map(|(g, s)| (*g, &s.received_udp_requests))
        .collect();

    assert_packets_properties(
        ref_client,
        &sim_client.sent_udp_requests,
        &received_udp_requests,
        &ref_client.expected_udp_handshakes,
        &sim_client.received_udp_replies,
        "UDP",
        global_dns_records,
        |sport, dport| tracing::info_span!(target: "assertions", "UDP", ?sport, ?dport),
    );
}

/// Asserts the following properties for all TCP handshakes:
/// 1. An TCP request on the client MUST result in an TCP response using the flipped src & dst IP and sport and dport.
/// 2. An TCP request on the gateway MUST target the intended resource:
///     - For CIDR resources, that is the actual CIDR resource IP.
///     - For DNS resources, the IP must match one of the resolved IPs for the domain.
/// 3. For DNS resources, the mapping of proxy IP to actual resource IP must be stable.
pub(crate) fn assert_tcp_packets_properties(
    ref_client: &RefClient,
    sim_client: &SimClient,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
    global_dns_records: &DnsRecords,
) {
    let received_tcp_requests = sim_gateways
        .iter()
        .map(|(g, s)| (*g, &s.received_tcp_requests))
        .collect();

    assert_packets_properties(
        ref_client,
        &sim_client.sent_tcp_requests,
        &received_tcp_requests,
        &ref_client.expected_tcp_exchanges,
        &sim_client.received_tcp_replies,
        "TCP",
        global_dns_records,
        |sport, dport| tracing::info_span!(target: "assertions", "TCP", ?sport, ?dport),
    );
}

pub(crate) fn assert_resource_status(ref_client: &RefClient, sim_client: &SimClient) {
    let expected_status_map = &ref_client.expected_resource_status();
    let actual_status_map = &sim_client.resource_status;

    if expected_status_map != actual_status_map {
        for (resource, expected_status) in expected_status_map {
            match actual_status_map.get(resource) {
                Some(actual_status) if actual_status != expected_status => {
                    tracing::error!(target: "assertions", %expected_status, %actual_status, %resource, "Resource status doesn't match");
                }
                Some(_) => {}
                None => {
                    tracing::error!(target: "assertions", %expected_status, %resource, "Missing resource status");
                }
            }
        }

        for (resource, actual_status) in actual_status_map {
            if expected_status_map.get(resource).is_none() {
                tracing::error!(target: "assertions", %actual_status, %resource, "Unexpected resource status");
            }
        }
    }
}

#[expect(clippy::too_many_arguments)]
fn assert_packets_properties<T, U>(
    ref_client: &RefClient,
    sent_requests: &HashMap<(T, U), IpPacket>,
    received_requests: &BTreeMap<GatewayId, &BTreeMap<u64, IpPacket>>,
    expected_handshakes: &BTreeMap<GatewayId, BTreeMap<u64, (Destination, T, U)>>,
    received_replies: &BTreeMap<(T, U), IpPacket>,
    packet_protocol: &str,
    global_dns_records: &DnsRecords,
    make_span: impl Fn(T, U) -> Span,
) where
    T: Copy + std::fmt::Debug,
    U: Copy + std::fmt::Debug,
    (T, U): ReplyTo + Hash + Eq + Ord,
{
    let unexpected_replies = find_unexpected_entries(
        &expected_handshakes.values().flatten().collect(),
        received_replies,
        |(_, (_, t_a, u_a)), b| (*t_a, *u_a) == b.reply_to(),
    );

    if !unexpected_replies.is_empty() {
        tracing::error!(target: "assertions", ?unexpected_replies, ?expected_handshakes, ?received_replies, "❌ Unexpected {packet_protocol} replies on client");
    }

    for (gid, expected_handshakes) in expected_handshakes.iter() {
        let received_requests = received_requests.get(gid).unwrap();

        let num_expected_handshakes = expected_handshakes.len();
        let num_actual_handshakes = received_requests.len();

        if num_expected_handshakes != num_actual_handshakes {
            tracing::error!(target: "assertions", %num_expected_handshakes, %num_actual_handshakes, %gid, "❌ Unexpected {packet_protocol} requests");
        } else {
            tracing::info!(target: "assertions", %num_expected_handshakes, %gid, "✅ Performed the expected {packet_protocol} handshakes");
        }
    }

    let mut mapping = HashMap::new();

    // Assert properties of the individual handshakes per gateway.
    // Due to connlib's implementation of NAT64, we cannot match the packets sent by the client to the packets arriving at the resource by port or ICMP identifier.
    // Thus, we rely on a custom u64 payload attached to all packets to uniquely identify every individual packet.
    for (gateway, expected_handshakes) in expected_handshakes {
        let received_requests = received_requests.get(gateway).unwrap();
        for (payload, (resource_dst, t, u)) in expected_handshakes {
            let _guard = make_span(*t, *u).entered();

            let Some(client_sent_request) = sent_requests.get(&(*t, *u)) else {
                tracing::error!(target: "assertions", "❌ Missing {packet_protocol} request on client");
                continue;
            };
            let Some(client_received_reply) = received_replies.get(&(*t, *u).reply_to()) else {
                tracing::error!(target: "assertions", "❌ Missing {packet_protocol} reply on client");
                continue;
            };
            assert_correct_src_and_dst_ips(client_sent_request, client_received_reply);

            let Some(gateway_received_request) = received_requests.get(payload) else {
                tracing::error!(target: "assertions", "❌ Missing {packet_protocol} request on gateway");
                continue;
            };

            {
                let expected = ref_client.tunnel_ip_for(gateway_received_request.source());
                let actual = gateway_received_request.source();

                if expected != actual {
                    tracing::error!(target: "assertions", %expected, %actual, "❌ Unexpected {packet_protocol} request source");
                }
            }

            match resource_dst {
                Destination::IpAddr(resource_dst) => {
                    assert_destination_is_cdir_resource(gateway_received_request, resource_dst)
                }
                Destination::DomainName { name, .. } => {
                    let domain = match ref_client.fully_qualify_using_search_domain(name.clone()) {
                        Ok(domain) => domain,
                        Err(e) => {
                            tracing::error!(target: "assertions", "Failed to fully-qualify domain: {e:#}");
                            return;
                        }
                    };

                    assert_destination_is_dns_resource(
                        gateway_received_request,
                        global_dns_records,
                        &domain,
                    );

                    assert_proxy_ip_mapping_is_stable(
                        client_sent_request,
                        gateway_received_request,
                        &mut mapping,
                    )
                }
            }
        }
    }
}

pub(crate) fn assert_dns_servers_are_valid(ref_client: &RefClient, sim_client: &SimClient) {
    let expected = ref_client.expected_dns_servers();
    let actual = sim_client.effective_dns_servers();

    if actual != expected {
        tracing::error!(target: "assertions", ?actual, ?expected, "❌ Effective DNS servers are incorrect");
    }
}

pub(crate) fn assert_routes_are_valid(ref_client: &RefClient, sim_client: &SimClient) {
    let (expected_ipv4, expected_ipv6) = ref_client.expected_routes();
    let (actual_ipv4, actual_ipv6) = (
        sim_client.ipv4_routes.clone(),
        sim_client.ipv6_routes.clone(),
    );

    if actual_ipv4 != expected_ipv4 {
        let expected_ipv4 = expected_ipv4.iter().join(", ");
        let actual_ipv4 = actual_ipv4.iter().join(", ");

        tracing::error!(target: "assertions", actual = ?actual_ipv4, expected = ?expected_ipv4, "❌ IPv4 routes don't match");
    }

    if actual_ipv6 != expected_ipv6 {
        let expected_ipv6 = expected_ipv6.iter().join(", ");
        let actual_ipv6 = actual_ipv6.iter().join(", ");

        tracing::error!(target: "assertions", actual = ?actual_ipv6, expected = ?expected_ipv6, "❌ IPv6 routes don't match");
    }
}

pub(crate) fn assert_udp_dns_packets_properties(ref_client: &RefClient, sim_client: &SimClient) {
    let unexpected_dns_replies = find_unexpected_entries(
        &ref_client.expected_udp_dns_handshakes,
        &sim_client.received_udp_dns_responses,
        |(_, id_a), (_, id_b)| id_a == id_b,
    );

    if !unexpected_dns_replies.is_empty() {
        tracing::error!(target: "assertions", ?unexpected_dns_replies, "❌ Unexpected UDP DNS replies on client");
    }

    for (dns_server, query_id) in ref_client.expected_udp_dns_handshakes.iter() {
        let _guard =
            tracing::info_span!(target: "assertions", "udp_dns", %query_id, %dns_server).entered();
        let key = &(*dns_server, *query_id);

        let queries = &sim_client.sent_udp_dns_queries;
        let responses = &sim_client.received_udp_dns_responses;

        let Some(client_sent_query) = queries.get(key) else {
            tracing::error!(target: "assertions", ?queries, "❌ Missing UDP DNS query on client");
            continue;
        };
        let Some(client_received_response) = responses.get(key) else {
            tracing::error!(target: "assertions", ?responses, "❌ Missing UDP DNS response on client");
            continue;
        };

        assert_correct_src_and_dst_ips(client_sent_query, client_received_response);
        assert_correct_src_and_dst_udp_ports(client_sent_query, client_received_response);
    }
}

pub(crate) fn assert_tcp_dns(ref_client: &RefClient, sim_client: &SimClient) {
    for (dns_server, query_id) in ref_client.expected_tcp_dns_handshakes.iter() {
        let _guard =
            tracing::info_span!(target: "assertions", "tcp_dns", %query_id, %dns_server).entered();
        let key = &(*dns_server, *query_id);

        let queries = &sim_client.sent_tcp_dns_queries;
        let responses = &sim_client.received_tcp_dns_responses;

        if queries.get(key).is_none() {
            tracing::error!(target: "assertions", ?queries, "❌ Missing TCP DNS query on client");
            continue;
        };
        if responses.get(key).is_none() {
            tracing::error!(target: "assertions", ?responses, "❌ Missing TCP DNS response on client");
            continue;
        };
    }
}

fn assert_correct_src_and_dst_ips(
    client_sent_request: &IpPacket,
    client_received_reply: &IpPacket,
) {
    let req_dst = client_sent_request.destination();
    let res_src = client_received_reply.source();

    if req_dst != res_src {
        tracing::error!(target: "assertions", %req_dst, %res_src, "❌ req dst IP != res src IP");
    } else {
        tracing::info!(target: "assertions", ip = %req_dst, "✅ req dst IP == res src IP");
    }

    let req_src = client_sent_request.source();
    let res_dst = client_received_reply.destination();

    if req_src != res_dst {
        tracing::error!(target: "assertions", %req_src, %res_dst, "❌ req src IP != res dst IP");
    } else {
        tracing::info!(target: "assertions", ip = %req_src, "✅ req src IP == res dst IP");
    }
}

fn assert_correct_src_and_dst_udp_ports(
    client_sent_request: &IpPacket,
    client_received_reply: &IpPacket,
) {
    let client_sent_request = client_sent_request.as_udp().unwrap();
    let client_received_reply = client_received_reply.as_udp().unwrap();

    let req_dst = client_sent_request.destination_port();
    let res_src = client_received_reply.source_port();

    if req_dst != res_src {
        tracing::error!(target: "assertions", %req_dst, %res_src, "❌ req dst port != res src port");
    } else {
        tracing::info!(target: "assertions", port = %req_dst, "✅ req dst port == res src port");
    }

    let req_src = client_sent_request.source_port();
    let res_dst = client_received_reply.destination_port();

    if req_src != res_dst {
        tracing::error!(target: "assertions", %req_src, %res_dst, "❌ req src port != res dst port");
    } else {
        tracing::info!(target: "assertions", port = %req_src, "✅ req src port == res dst port");
    }
}

fn assert_destination_is_cdir_resource(gateway_received_request: &IpPacket, expected: &IpAddr) {
    let actual = gateway_received_request.destination();

    if actual != *expected {
        tracing::error!(target: "assertions", %actual, %expected, "❌ Incorrect resource destination");
    } else {
        tracing::info!(target: "assertions", ip = %actual, "✅ ICMP request targets correct resource");
    }
}

fn assert_destination_is_dns_resource(
    gateway_received_request: &IpPacket,
    global_dns_records: &DnsRecords,
    domain: &dns_types::DomainName,
) {
    let actual = gateway_received_request.destination();
    let possible_resource_ips = global_dns_records
        .domain_ips_iter(domain)
        .collect::<Vec<_>>();

    if !possible_resource_ips.contains(&actual) {
        tracing::error!(target: "assertions", %domain, %actual, ?possible_resource_ips, "❌ Unknown resource IP");
    } else {
        tracing::info!(target: "assertions", %domain, ip = %actual, "✅ Resource IP is valid");
    }
}

/// Assert that the mapping of proxy IP to resource destination is stable.
///
/// How connlib assigns proxy IPs for domains is an implementation detail.
/// Yet, we care that it remains stable to ensure that any form of sticky sessions don't get broken (i.e. packets to one IP are always routed to the same IP on the gateway).
/// To assert this, we build up a map as we iterate through all packets that have been sent.
fn assert_proxy_ip_mapping_is_stable(
    client_sent_request: &IpPacket,
    gateway_received_request: &IpPacket,
    mapping: &mut HashMap<IpAddr, IpAddr>,
) {
    let proxy_ip = client_sent_request.destination();
    let real_ip = gateway_received_request.destination();

    match mapping.entry(proxy_ip) {
        Entry::Vacant(v) => {
            // We have to gradually discover connlib's mapping ...
            // For the first packet, we just save the IP that we ended up talking to.
            v.insert(real_ip);
        }
        Entry::Occupied(o) => {
            let actual = real_ip;
            let expected = *o.get();

            if actual != expected {
                tracing::error!(target: "assertions", %proxy_ip, %actual, %expected, "❌ IP mapping is not stable");
            } else {
                tracing::info!(target: "assertions", %proxy_ip, %actual, "✅ IP mapping is stable");
            }
        }
    }
}

fn find_unexpected_entries<'a, E, K, V>(
    expected: &VecDeque<E>,
    actual: &'a BTreeMap<K, V>,
    is_expected: impl Fn(&E, &K) -> bool,
) -> Vec<&'a V> {
    actual
        .iter()
        .filter(|(k, _)| !expected.iter().any(|e| is_expected(e, k)))
        .map(|(_, v)| v)
        .collect()
}

/// Tracks whether any [`Level::ERROR`] events are emitted and panics on `Drop` in case.
pub(crate) struct PanicOnErrorEvents<S> {
    subscriber: PhantomData<S>,
    has_seen_error: AtomicBool,
    index: u32,
}

impl<S> PanicOnErrorEvents<S> {
    pub(crate) fn new(index: u32) -> Self {
        Self {
            subscriber: PhantomData,
            has_seen_error: Default::default(),
            index,
        }
    }
}

impl<S> Drop for PanicOnErrorEvents<S> {
    fn drop(&mut self) {
        if self.has_seen_error.load(Ordering::SeqCst) {
            panic!("Testcase {} failed", self.index);
        }
    }
}

impl<S> Layer<S> for PanicOnErrorEvents<S>
where
    S: Subscriber,
{
    fn on_event(
        &self,
        _event: &tracing::Event<'_>,
        _ctx: tracing_subscriber::layer::Context<'_, S>,
    ) {
        if _event.metadata().level() == &Level::ERROR {
            self.has_seen_error.store(true, Ordering::SeqCst)
        }
    }
}
