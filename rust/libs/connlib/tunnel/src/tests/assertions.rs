use crate::tests::ref_gateway::RefGateway;

use super::{
    dns_records::DnsRecords,
    ref_client::RefClient,
    sim_client::SimClient,
    sim_gateway::SimGateway,
    stub_portal::StubPortal,
    transition::{Destination, ReplyTo},
};
use connlib_model::{ClientId, GatewayId};
use ip_packet::IpPacket;
use itertools::Itertools;
use std::{
    collections::{BTreeMap, HashMap, VecDeque, hash_map::Entry},
    hash::Hash,
    iter,
    marker::PhantomData,
    net::{IpAddr, SocketAddr},
    sync::atomic::{AtomicBool, Ordering},
    time::Instant,
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
    ref_clients: &BTreeMap<ClientId, &RefClient>,
    ref_gateways: &BTreeMap<GatewayId, &RefGateway>,
    sim_clients: &BTreeMap<ClientId, &SimClient>,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
    global_dns_records: &DnsRecords,
) {
    assert_packets_properties(
        ref_clients,
        ref_gateways,
        sim_clients,
        sim_gateways,
        global_dns_records,
        |sim_client| &sim_client.sent_icmp_requests,
        |ref_client| &ref_client.expected_gateway_icmp_handshakes,
        |ref_client| &ref_client.expected_client_icmp_handshakes,
        |sim_client| &sim_client.received_icmp_replies,
        |sim_gateway| &sim_gateway.received_icmp_requests,
        |sim_client| &sim_client.received_icmp_requests,
        "ICMP",
        |seq, identifier| tracing::info_span!(target: "assertions", "ICMP", ?seq, ?identifier),
        |ref_client, dst, _, _| ref_client.any_resource_allows_icmp(dst),
    );
}

/// Asserts the following properties for all UDP handshakes:
/// 1. An UDP request on the client MUST result in an UDP response using the flipped src & dst IP and sport and dport.
/// 2. An UDP request on the gateway MUST target the intended resource:
///     - For CIDR resources, that is the actual CIDR resource IP.
///     - For DNS resources, the IP must match one of the resolved IPs for the domain.
/// 3. For DNS resources, the mapping of proxy IP to actual resource IP must be stable.
pub(crate) fn assert_udp_packets_properties(
    ref_clients: &BTreeMap<ClientId, &RefClient>,
    ref_gateways: &BTreeMap<GatewayId, &RefGateway>,
    sim_clients: &BTreeMap<ClientId, &SimClient>,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
    global_dns_records: &DnsRecords,
) {
    assert_packets_properties(
        ref_clients,
        ref_gateways,
        sim_clients,
        sim_gateways,
        global_dns_records,
        |sim_client| &sim_client.sent_udp_requests,
        |ref_client| &ref_client.expected_gateway_udp_handshakes,
        |ref_client| &ref_client.expected_client_udp_handshakes,
        |sim_client| &sim_client.received_udp_replies,
        |sim_gateway| &sim_gateway.received_udp_requests,
        |sim_client| &sim_client.received_udp_requests,
        "UDP",
        |sport, dport| tracing::info_span!(target: "assertions", "UDP", ?sport, ?dport),
        |ref_client, dst, _, dport| ref_client.any_resource_allows_udp_on_port(dst, dport.0),
    );
}

fn assert_packets_properties<T, U>(
    ref_clients: &BTreeMap<ClientId, &RefClient>,
    ref_gateways: &BTreeMap<GatewayId, &RefGateway>,
    sim_clients: &BTreeMap<ClientId, &SimClient>,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
    global_dns_records: &DnsRecords,
    get_sent_requests: impl Fn(&SimClient) -> &BTreeMap<(T, U), (Instant, IpPacket)>,
    get_expected_gateway_handshakes: impl Fn(
        &RefClient,
    )
        -> &BTreeMap<GatewayId, BTreeMap<u64, (Destination, T, U)>>,
    get_expected_client_handshakes: impl Fn(
        &RefClient,
    )
        -> &BTreeMap<ClientId, BTreeMap<u64, (Destination, T, U)>>,
    get_received_replies: impl Fn(&SimClient) -> &BTreeMap<(T, U), IpPacket>,
    get_received_requests_on_gateway: impl Fn(&SimGateway) -> &BTreeMap<u64, (Instant, IpPacket)>,
    get_received_requests_on_client: impl Fn(&SimClient) -> &BTreeMap<u64, (Instant, IpPacket)>,
    packet_protocol: &str,
    make_span: impl Fn(T, U) -> Span,
    any_resource_allows: impl Fn(&RefClient, &Destination, T, U) -> bool,
) where
    T: Copy + std::fmt::Debug,
    U: Copy + std::fmt::Debug,
    (T, U): ReplyTo + Hash + Eq + Ord,
{
    let all_sent_requests = sim_clients
        .iter()
        .flat_map(|(cid, sim_client)| {
            get_sent_requests(sim_client)
                .iter()
                .map(move |(key, packet)| ((*cid, *key), packet.clone()))
        })
        .collect::<BTreeMap<_, _>>();

    let all_expected_gateway_handshakes = ref_clients
        .iter()
        .flat_map(|(cid, ref_client)| {
            get_expected_gateway_handshakes(ref_client).iter().flat_map(
                move |(gateway_id, handshakes)| {
                    handshakes
                        .iter()
                        .map(move |(payload, (destination, t, u))| {
                            (*gateway_id, *payload, (*cid, destination.clone(), *t, *u))
                        })
                },
            )
        })
        .fold(
            BTreeMap::<_, BTreeMap<_, _>>::new(),
            |mut acc, (gateway_id, payload, value)| {
                acc.entry(gateway_id).or_default().insert(payload, value);
                acc
            },
        );

    let all_expected_client_handshakes = ref_clients
        .iter()
        .flat_map(|(cid, ref_client)| {
            get_expected_client_handshakes(ref_client).iter().flat_map(
                move |(client_id, handshakes)| {
                    handshakes
                        .iter()
                        .map(move |(payload, (destination, t, u))| {
                            (*client_id, *payload, (*cid, destination.clone(), *t, *u))
                        })
                },
            )
        })
        .fold(
            BTreeMap::<_, BTreeMap<_, _>>::new(),
            |mut acc, (client_id, payload, value)| {
                acc.entry(client_id).or_default().insert(payload, value);
                acc
            },
        );

    let all_received_replies_on_client = sim_clients
        .iter()
        .flat_map(|(cid, sim_client)| {
            get_received_replies(sim_client)
                .iter()
                .map(move |(key, packet)| ((*cid, *key), packet.clone()))
        })
        .collect::<BTreeMap<_, _>>();

    let received_requests_by_gateway = sim_gateways
        .iter()
        .map(|(g, s)| (*g, get_received_requests_on_gateway(s)))
        .collect::<BTreeMap<_, _>>();
    let received_requests_by_client = sim_clients
        .iter()
        .map(|(g, s)| (*g, get_received_requests_on_client(s)))
        .collect::<BTreeMap<_, _>>();
    let dns_query_timestamps = sim_gateways
        .iter()
        .map(|(g, s)| (*g, &s.dns_query_timestamps))
        .collect::<BTreeMap<_, _>>();

    let unexpected_replies = find_unexpected_entries(
        &iter::empty()
            .chain(all_expected_gateway_handshakes.values().flatten())
            .chain(all_expected_client_handshakes.values().flatten())
            .collect(),
        &all_received_replies_on_client,
        |(_, (_, _, t_a, u_a)), (_, b)| (*t_a, *u_a) == b.reply_to(),
    );

    if !unexpected_replies.is_empty() {
        tracing::error!(target: "assertions", ?unexpected_replies, ?all_expected_gateway_handshakes, ?all_received_replies_on_client, "❌ Unexpected {packet_protocol} replies on client");
    }

    let mut mappings = HashMap::new();

    // Assert properties of the individual handshakes per gateway.
    // Due to connlib's implementation of NAT64, we cannot match the packets sent by the client to the packets arriving at the resource by port or ICMP identifier.
    // Thus, we rely on a custom u64 payload attached to all packets to uniquely identify every individual packet.
    for (gateway, expected_handshakes) in &all_expected_gateway_handshakes {
        let Some(ref_gateway) = ref_gateways.get(gateway) else {
            tracing::error!(target: "assertions", %gateway, "❌ Unknown Gateway");
            continue;
        };
        let received_requests_for_gateway = received_requests_by_gateway.get(gateway).unwrap();
        let dns_query_timestamps_for_gateway = dns_query_timestamps.get(gateway).unwrap();

        let mut num_expected_handshakes = expected_handshakes.len();

        for (payload, (cid, resource_dst, t, u)) in expected_handshakes {
            let _guard = make_span(*t, *u).entered();

            let ref_client = ref_clients.get(cid).unwrap();

            let Some((_, client_sent_request)) = all_sent_requests.get(&(*cid, (*t, *u))) else {
                tracing::error!(target: "assertions", %cid, "❌ Missing {packet_protocol} request on client");
                continue;
            };
            let Some(client_received_reply) =
                all_received_replies_on_client.get(&(*cid, (*t, *u).reply_to()))
            else {
                tracing::error!(target: "assertions", %cid, "❌ Missing {packet_protocol} reply on client");
                continue;
            };
            assert_correct_src_and_dst_ips(client_sent_request, client_received_reply);

            let Some((packet_sent_at, gateway_received_request)) =
                received_requests_for_gateway.get(payload)
            else {
                // An "administratively prohibited" error is produced by the gateway when a
                // resource filter blocks the packet before it ever reaches the network.
                // This is only tolerated if all filters on matching resources block this packet.
                if let Ok(Some((_, icmp_error))) = client_received_reply.icmp_error()
                    && icmp_error.is_unreachable_prohibited()
                    && any_resource_allows(ref_client, resource_dst, *t, *u)
                {
                    tracing::error!(target: "assertions", %cid, "❌ Received ICMP prohibited error but at least one resource allows this {packet_protocol} packet");
                    continue;
                }

                if client_received_reply
                    .icmp_error()
                    .is_ok_and(|e| e.is_some())
                {
                    num_expected_handshakes -= 1;
                    continue;
                }

                tracing::error!(target: "assertions", %cid, "❌ Missing {packet_protocol} request on gateway");
                continue;
            };

            {
                let expected = ref_client.tunnel_ip_for(gateway_received_request.source());
                let actual = gateway_received_request.source();

                if expected != actual {
                    tracing::error!(target: "assertions", %cid, %expected, %actual, "❌ Unexpected {packet_protocol} request source");
                }
            }

            if !any_resource_allows(ref_client, resource_dst, *t, *u)
                && !is_tunnel_ip(ref_gateway, resource_dst)
            {
                tracing::error!(target: "assertions", %cid, "❌ {packet_protocol} packet was delivered to resource but no traffic filter allows it");
            }

            match resource_dst {
                Destination::IpAddr(resource_dst) => {
                    assert_destination_is_cdir_resource(gateway_received_request, resource_dst)
                }
                Destination::DomainName { name, .. } => {
                    let Some(query_timestamps) = dns_query_timestamps_for_gateway.get(name) else {
                        tracing::error!(%cid, %name, "Should have resolved domain at least once");
                        continue;
                    };

                    // To correct assert whether the packet was routed to the correct IP, we need to find the timestamp of the DNS query closest to the packet timestamp.
                    // In other words: Packets should always use the IPs that were most recently resolved when they were sent.
                    let Some(dns_record_snapshot) = query_timestamps
                        .iter()
                        .filter(|query_timestamp| *query_timestamp <= packet_sent_at)
                        .max()
                    else {
                        tracing::error!(%cid, %name, "Should have a relevant query timestamp");
                        continue;
                    };

                    // Split the proxy IP mapping by DNS record snapshot.
                    //
                    // When we re-resolve DNS, the mapping is allowed to change.
                    let mapping = mappings.entry(dns_record_snapshot).or_default();

                    assert_destination_is_dns_resource(
                        gateway_received_request,
                        global_dns_records,
                        name,
                        *dns_record_snapshot,
                    );

                    assert_proxy_ip_mapping_is_stable(
                        client_sent_request,
                        gateway_received_request,
                        mapping,
                    )
                }
            }
        }

        let num_actual_handshakes = received_requests_for_gateway.len();

        if num_expected_handshakes != num_actual_handshakes {
            tracing::error!(target: "assertions", %num_expected_handshakes, %num_actual_handshakes, %gateway, "❌ Unexpected {packet_protocol} requests");
        } else {
            tracing::info!(target: "assertions", %num_expected_handshakes, %gateway, "✅ Performed the expected {packet_protocol} handshakes");
        }
    }

    for (dst_client_id, expected_handshakes) in &all_expected_client_handshakes {
        let mut num_expected_handshakes = expected_handshakes.len();

        let received_requests_for_client = received_requests_by_client.get(dst_client_id).unwrap();

        for (payload, (src_client_id, _, t, u)) in expected_handshakes {
            let _guard = make_span(*t, *u).entered();

            let src_ref_client = ref_clients.get(src_client_id).unwrap();
            let dst_ref_client = ref_clients.get(dst_client_id).unwrap();

            let Some((sent_at, client_sent_request)) =
                all_sent_requests.get(&(*src_client_id, (*t, *u)))
            else {
                tracing::error!(target: "assertions", %src_client_id, "❌ Missing {packet_protocol} request on client");
                continue;
            };
            let Some(client_received_reply) =
                all_received_replies_on_client.get(&(*src_client_id, (*t, *u).reply_to()))
            else {
                // If the request was made after we reset our connections, missing a reply is okay.
                if dst_ref_client.has_reset_connections_within_ice_timeout(*sent_at) {
                    tracing::debug!(target: "assertions", %dst_client_id, "Destination client reset its connections and packet got lost");
                    num_expected_handshakes -= 1;
                    continue;
                }

                tracing::error!(target: "assertions", %src_client_id, "❌ Missing {packet_protocol} reply on client");
                continue;
            };
            assert_correct_src_and_dst_ips(client_sent_request, client_received_reply);

            let Some((_, client_received_request)) = received_requests_for_client.get(payload)
            else {
                tracing::error!(target: "assertions", %src_client_id, "❌ Missing {packet_protocol} request on client");
                continue;
            };

            {
                let expected = src_ref_client.tunnel_ip_for(client_received_request.source());
                let actual = client_received_request.source();

                if expected != actual {
                    tracing::error!(target: "assertions", %src_client_id, %expected, %actual, "❌ Unexpected {packet_protocol} request source");
                }
            }
        }

        let num_actual_handshakes = received_requests_for_client.len();

        if num_expected_handshakes != num_actual_handshakes {
            tracing::error!(target: "assertions", %num_expected_handshakes, %num_actual_handshakes, %dst_client_id, "❌ Unexpected {packet_protocol} requests");
        } else {
            tracing::info!(target: "assertions", %num_expected_handshakes, %dst_client_id, "✅ Performed the expected {packet_protocol} handshakes");
        }
    }
}

pub(crate) fn assert_tcp_connections(ref_client: &RefClient, sim_client: &SimClient) {
    for (src, dst, sport, dport) in ref_client.expected_tcp_connections.keys() {
        let src = SocketAddr::new(*src, sport.0);
        let received_icmp_error_for_tuple = sim_client.failed_tcp_packets.get(&(*sport, *dport));

        let Some((socket, local)) = sim_client.tcp_client.iter_sockets().find_map(|s| {
            let endpoint = s.local_endpoint()?;

            (l3_tcp::IpEndpoint::from(src) == endpoint).then_some((s, endpoint))
        }) else {
            // An ICMP "administratively prohibited" error is only expected when every
            // resource that matches this destination blocks TCP on this port.  If at
            // least one resource allows it, the error is a bug.
            if let Some(icmp_error) = received_icmp_error_for_tuple
                && icmp_error.is_unreachable_prohibited()
                && ref_client.any_resource_allows_tcp_on_port(dst, dport.0)
            {
                tracing::error!(target: "assertions", %src, port = %dport.0, "Received ICMP error for TCP connection but at least one matching resource allows this port");
                continue;
            }

            if received_icmp_error_for_tuple.is_some() {
                continue;
            }

            tracing::error!(target: "assertions", %src, "Missing TCP connection");
            continue;
        };

        if !ref_client.any_resource_allows_tcp_on_port(dst, dport.0) {
            tracing::error!(target: "assertions", %src, port = %dport.0, "TCP connection was established but no traffic filter allows this port");
        }

        let Some(remote) = socket.remote_endpoint() else {
            tracing::error!(target: "assertions", %src, "TCP socket does not have a remote endpoint");
            continue;
        };

        let port = remote.port;

        if port == dport.0 {
            tracing::info!(target: "assertions", %port, "TCP connection is targeting expected port");
        } else {
            tracing::error!(target: "assertions", expected = %dport.0, actual = %port, "TCP connection dst port does not match");
        }

        let actual = socket.state();
        let expected = l3_tcp::State::Established;

        if actual == expected {
            tracing::info!(target: "assertions", %local, %remote, "TCP connection is {expected}");
        } else {
            tracing::error!(target: "assertions", %actual, %local, %remote, "TCP connection is not {expected}");
        }

        if received_icmp_error_for_tuple.is_some() {
            tracing::error!(target: "assertions", %local, %remote, "TCP socket should have been reset from ICMP error");
        }
    }
}

pub(crate) fn assert_resource_status(ref_client: &RefClient, sim_client: &SimClient) {
    use connlib_model::ResourceStatus::*;

    let expected_status_map = &ref_client.expected_resource_status();
    let actual_status_map = &sim_client.resource_status;
    let maybe_online_resources = ref_client.maybe_online_resources();

    if expected_status_map != actual_status_map {
        for (resource, expected_status) in expected_status_map {
            match actual_status_map.get(resource) {
                Some(&Online)
                    if expected_status == &Unknown && maybe_online_resources.contains(resource) => {
                }
                Some(&Unknown)
                    if expected_status == &Online && maybe_online_resources.contains(resource) => {}

                Some(actual_status) if actual_status != expected_status => {
                    tracing::error!(target: "assertions", %expected_status, %actual_status, %resource, ?maybe_online_resources, "Resource status doesn't match");
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

pub(crate) fn assert_dns_servers_are_valid(
    ref_client: &RefClient,
    sim_client: &SimClient,
    portal: &StubPortal,
) {
    let expected = ref_client.expected_dns_servers(portal.upstream_do53(), portal.upstream_doh());
    let actual = sim_client.effective_dns_servers();

    if actual != expected {
        tracing::error!(target: "assertions", ?actual, ?expected, "❌ Effective DNS servers are incorrect");
    }
}

pub(crate) fn assert_search_domain_is_valid(portal: &StubPortal, sim_client: &SimClient) {
    let expected = portal.search_domain();
    let actual = sim_client.effective_search_domain();

    if actual != expected {
        tracing::error!(target: "assertions", ?actual, ?expected, "❌ Search domain is incorrect");
    }
}

pub(crate) fn assert_routes_are_valid(ref_client: &RefClient, sim_client: &SimClient) {
    let expected = ref_client.expected_routes();
    let actual = sim_client.routes.clone();

    if actual != expected {
        let expected = expected.iter().join(", ");
        let actual = actual.iter().join(", ");

        tracing::error!(target: "assertions", ?actual, ?expected, "❌ Routes don't match");
    }
}

pub(crate) fn assert_udp_dns_packets_properties(ref_client: &RefClient, sim_client: &SimClient) {
    let unexpected_dns_replies = find_unexpected_entries(
        &ref_client.expected_udp_dns_handshakes,
        &sim_client.received_udp_dns_responses,
        |(_, id_a, _), (_, id_b, _)| id_a == id_b,
    );

    if !unexpected_dns_replies.is_empty() {
        tracing::error!(target: "assertions", ?unexpected_dns_replies, "❌ Unexpected UDP DNS replies on client");
    }

    for (dns_server, query_id, local_port) in ref_client.expected_udp_dns_handshakes.iter() {
        let _guard =
            tracing::info_span!(target: "assertions", "udp_dns", %query_id, %dns_server).entered();
        let key = &(dns_server.clone(), *query_id, *local_port);

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
        let key = &(dns_server.clone(), *query_id);

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
    at: Instant,
) {
    let actual = gateway_received_request.destination();
    let possible_resource_ips = global_dns_records
        .domain_ips_iter(domain, at)
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

fn is_tunnel_ip(g: &RefGateway, dst: &Destination) -> bool {
    let Destination::IpAddr(ip) = dst else {
        return false;
    };

    g.tunnel_ip_for(*ip) == *ip
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
