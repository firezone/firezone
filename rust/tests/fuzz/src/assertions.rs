use super::{
    dns_records::DnsRecords,
    icmp_error_hosts::IcmpErrorHosts,
    probe::{
        ExpectedOutcome, ExpectedProbe, ProbeEvent, ProbeEventKind, ProbeId, ProbeProtocol,
        ProbeRequest, RejectionResponse, Remote, TraceRequirement,
    },
    ref_client::RefClient,
    sim_client::SimClient,
    sim_gateway::SimGateway,
    stub_portal::StubPortal,
    transition::Destination,
};
use connlib_model::{ClientId, GatewayId};
use dns_types::DomainName;
use ip_packet::{Icmpv4Type, Icmpv6Type, IpPacket, Layer4Protocol};
use itertools::Itertools;
use std::{
    collections::{BTreeMap, HashMap, VecDeque, hash_map::Entry},
    marker::PhantomData,
    net::{IpAddr, SocketAddr},
    sync::atomic::{AtomicBool, Ordering},
    time::Instant,
};
use tracing::{Level, Subscriber};
use tracing_subscriber::Layer;

/// Compares each expected application probe with all endpoint observations.
pub(crate) fn assert_probes(
    expected_probes: &BTreeMap<ProbeId, ExpectedProbe>,
    ref_clients: &BTreeMap<ClientId, &RefClient>,
    sim_clients: &BTreeMap<ClientId, &SimClient>,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
    global_dns_records: &DnsRecords,
    icmp_error_hosts: &IcmpErrorHosts,
) {
    let mut observed = BTreeMap::<ProbeId, Vec<&ProbeEvent>>::new();

    for event in sim_clients
        .values()
        .flat_map(|client| client.probe_events.iter())
        .chain(
            sim_gateways
                .values()
                .flat_map(|gateway| gateway.probe_events.iter()),
        )
    {
        observed.entry(event.id).or_default().push(event);
    }

    for id in observed
        .keys()
        .filter(|id| !expected_probes.contains_key(id))
    {
        tracing::error!(target: "assertions", ?id, "Unexpected probe observations");
    }

    let mut mappings = BTreeMap::<(ClientId, DomainName, Instant), HashMap<IpAddr, IpAddr>>::new();

    for expected in expected_probes.values() {
        let events = observed
            .get(&expected.id)
            .map(Vec::as_slice)
            .unwrap_or_default();
        let trace = match observed_trace(expected, events) {
            Ok(trace) => trace,
            Err(reason) => {
                tracing::debug!(target: "assertions", ?expected, ?events, %reason);
                tracing::error!(target: "assertions", id = ?expected.id, %reason, "Probe trace does not match");
                continue;
            }
        };

        assert_injected_probe(expected, trace.injected);

        match expected.outcome {
            ExpectedOutcome::Dropped => {}
            ExpectedOutcome::Delivered { .. } => {
                let Some(delivered) = trace.delivered else {
                    continue;
                };
                let Some(returned) = trace.returned else {
                    continue;
                };

                assert_delivered_probe(
                    expected,
                    trace.injected,
                    delivered,
                    ref_clients,
                    sim_gateways,
                    global_dns_records,
                    &mut mappings,
                );
                assert_delivered_return(
                    expected,
                    trace.injected,
                    delivered,
                    returned,
                    icmp_error_hosts,
                );
            }
            ExpectedOutcome::Rejected { response, .. } => {
                let Some(returned) = trace.returned else {
                    continue;
                };

                assert_icmp_error_return(expected, trace.injected, returned, Some(response));
            }
        }
    }
}

#[derive(Debug)]
struct ObservedTrace<'a> {
    injected: &'a ProbeEvent,
    delivered: Option<&'a ProbeEvent>,
    returned: Option<&'a ProbeEvent>,
}

fn observed_trace<'a>(
    expected: &ExpectedProbe,
    events: &'a [&'a ProbeEvent],
) -> Result<ObservedTrace<'a>, &'static str> {
    let injected = events
        .iter()
        .copied()
        .filter(|event| matches!(event.kind, ProbeEventKind::Injected { .. }))
        .collect::<Vec<_>>();
    let delivered = events
        .iter()
        .copied()
        .filter(|event| matches!(event.kind, ProbeEventKind::Delivered { .. }))
        .collect::<Vec<_>>();
    let returned = events
        .iter()
        .copied()
        .filter(|event| matches!(event.kind, ProbeEventKind::Returned { .. }))
        .collect::<Vec<_>>();

    if injected.len() != 1 {
        return Err("expected exactly one injection");
    }

    let injected = injected[0];
    if injected.kind
        != (ProbeEventKind::Injected {
            client: expected.origin,
        })
    {
        return Err("probe was injected by the wrong client");
    }

    let absence_is_allowed = matches!(
        expected.trace_requirement,
        TraceRequirement::ExactOrNoRemoteEvents(_)
    );
    if absence_is_allowed && delivered.is_empty() && returned.is_empty() {
        return Ok(ObservedTrace {
            injected,
            delivered: None,
            returned: None,
        });
    }

    match expected.outcome {
        ExpectedOutcome::Dropped => {
            if !delivered.is_empty() || !returned.is_empty() {
                return Err("dropped probe produced remote events");
            }

            Ok(ObservedTrace {
                injected,
                delivered: None,
                returned: None,
            })
        }
        ExpectedOutcome::Delivered {
            remote: expected_remote,
            ..
        } => {
            if delivered.len() != 1 {
                return Err("delivered probe did not have exactly one delivery");
            }
            if returned.len() != 1 {
                return Err("delivered probe did not have exactly one return");
            }
            if delivered[0].kind
                != (ProbeEventKind::Delivered {
                    remote: expected_remote,
                })
            {
                return Err("probe was delivered to the wrong remote");
            }
            if returned[0].kind
                != (ProbeEventKind::Returned {
                    client: expected.origin,
                })
            {
                return Err("probe returned to the wrong client");
            }

            Ok(ObservedTrace {
                injected,
                delivered: Some(delivered[0]),
                returned: Some(returned[0]),
            })
        }
        ExpectedOutcome::Rejected { .. } => {
            if !delivered.is_empty() {
                return Err("rejected probe was delivered");
            }
            if returned.len() != 1 {
                return Err("rejected probe did not have exactly one return");
            }
            if returned[0].kind
                != (ProbeEventKind::Returned {
                    client: expected.origin,
                })
            {
                return Err("rejected probe returned to the wrong client");
            }

            Ok(ObservedTrace {
                injected,
                delivered: None,
                returned: Some(returned[0]),
            })
        }
    }
}

fn assert_injected_probe(expected: &ExpectedProbe, injected: &ProbeEvent) {
    if injected.at != expected.sent_at {
        tracing::error!(target: "assertions", id = ?expected.id, "Probe was injected at the wrong time");
    }

    if injected.packet.source() != expected.request.source() {
        tracing::error!(target: "assertions", id = ?expected.id, "Probe has the wrong source");
    }

    if let Destination::IpAddr(expected_destination) = expected.request.destination()
        && injected.packet.destination() != *expected_destination
    {
        tracing::error!(target: "assertions", id = ?expected.id, "Probe has the wrong destination");
    }

    assert_probe_payload(expected.id, &injected.packet);

    match &expected.request {
        ProbeRequest::Icmp {
            seq, identifier, ..
        } => {
            let Some((actual_seq, actual_identifier, _)) = icmp_echo_request(&injected.packet)
            else {
                tracing::error!(target: "assertions", id = ?expected.id, "Injected probe is not an ICMP echo request");
                return;
            };

            if (actual_seq, actual_identifier) != (seq.0, identifier.0) {
                tracing::error!(target: "assertions", id = ?expected.id, "ICMP probe identifiers do not match");
            }
        }
        ProbeRequest::Udp { sport, dport, .. } => {
            let Some(udp) = injected.packet.as_udp() else {
                tracing::error!(target: "assertions", id = ?expected.id, "Injected probe is not UDP");
                return;
            };

            if (udp.source_port(), udp.destination_port()) != (sport.0, dport.0) {
                tracing::error!(target: "assertions", id = ?expected.id, "UDP probe ports do not match");
            }
        }
    }
}

fn assert_delivered_probe(
    expected: &ExpectedProbe,
    injected: &ProbeEvent,
    delivered: &ProbeEvent,
    ref_clients: &BTreeMap<ClientId, &RefClient>,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
    global_dns_records: &DnsRecords,
    mappings: &mut BTreeMap<(ClientId, DomainName, Instant), HashMap<IpAddr, IpAddr>>,
) {
    assert_probe_payload(expected.id, &delivered.packet);

    if probe_payload(&injected.packet) != probe_payload(&delivered.packet) {
        tracing::error!(target: "assertions", id = ?expected.id, "Probe payload changed in transit");
    }

    let ref_client = ref_clients.get(&expected.origin).unwrap();
    let expected_source = ref_client.tunnel_ip_for(delivered.packet.source());
    if delivered.packet.source() != expected_source {
        tracing::error!(target: "assertions", id = ?expected.id, "Delivered probe has the wrong source");
    }

    match expected.request.destination() {
        Destination::IpAddr(destination) => {
            assert_destination_is_ip(&delivered.packet, destination);
        }
        Destination::DomainName { name, .. } => {
            let ProbeEventKind::Delivered {
                remote: Remote::Gateway(gateway),
            } = delivered.kind
            else {
                tracing::error!(target: "assertions", id = ?expected.id, "DNS probe was not delivered to a gateway");
                return;
            };
            let Some(query_timestamps) = sim_gateways
                .get(&gateway)
                .and_then(|gateway| gateway.dns_query_timestamps.get(name))
            else {
                tracing::error!(target: "assertions", id = ?expected.id, "DNS probe has no resolution timestamp");
                return;
            };
            let Some(snapshot) = query_timestamps
                .iter()
                .copied()
                .filter(|timestamp| *timestamp <= delivered.at)
                .max()
            else {
                tracing::error!(target: "assertions", id = ?expected.id, "DNS probe has no applicable resolution");
                return;
            };

            assert_destination_is_dns_resource(
                &delivered.packet,
                global_dns_records,
                name,
                snapshot,
            );

            let mapping = mappings
                .entry((expected.origin, name.clone(), snapshot))
                .or_default();
            assert_proxy_ip_mapping_is_stable(&injected.packet, &delivered.packet, mapping);
        }
    }
}

fn assert_delivered_return(
    expected: &ExpectedProbe,
    injected: &ProbeEvent,
    delivered: &ProbeEvent,
    returned: &ProbeEvent,
    icmp_error_hosts: &IcmpErrorHosts,
) {
    if remote_returns_icmp_error(expected, delivered, icmp_error_hosts) {
        assert_icmp_error_return(expected, injected, returned, None);
        return;
    }

    assert_echo_return(expected, injected, returned);
}

fn remote_returns_icmp_error(
    expected: &ExpectedProbe,
    delivered: &ProbeEvent,
    icmp_error_hosts: &IcmpErrorHosts,
) -> bool {
    let is_icmp_peer = matches!(
        (&expected.request, expected.outcome),
        (
            ProbeRequest::Icmp { .. },
            ExpectedOutcome::Delivered {
                remote: Remote::Client(_),
                ..
            }
        )
    );

    !is_icmp_peer
        && icmp_error_hosts
            .icmp_error_for_ip(delivered.packet.destination())
            .is_some()
}

fn assert_echo_return(expected: &ExpectedProbe, injected: &ProbeEvent, returned: &ProbeEvent) {
    assert_correct_src_and_dst_ips(&injected.packet, &returned.packet);

    match &expected.request {
        ProbeRequest::Icmp { .. } => {
            let Some((request_seq, request_identifier, request_payload)) =
                icmp_echo_request(&injected.packet)
            else {
                tracing::error!(target: "assertions", id = ?expected.id, "Injected probe is not an ICMP echo request");
                return;
            };
            let Some((reply_seq, reply_identifier, reply_payload)) =
                icmp_echo_reply(&returned.packet)
            else {
                tracing::error!(target: "assertions", id = ?expected.id, "Probe did not return an ICMP echo reply");
                return;
            };

            if (request_seq, request_identifier) != (reply_seq, reply_identifier) {
                tracing::error!(target: "assertions", id = ?expected.id, "ICMP reply identifiers do not match");
            }
            if request_payload != reply_payload {
                tracing::error!(target: "assertions", id = ?expected.id, "ICMP reply payload does not match");
            }
        }
        ProbeRequest::Udp { .. } => {
            let Some(request) = injected.packet.as_udp() else {
                tracing::error!(target: "assertions", id = ?expected.id, "Injected probe is not UDP");
                return;
            };
            let Some(reply) = returned.packet.as_udp() else {
                tracing::error!(target: "assertions", id = ?expected.id, "Probe did not return a UDP reply");
                return;
            };

            assert_correct_src_and_dst_udp_ports(&injected.packet, &returned.packet);

            if request.payload() != reply.payload() {
                tracing::error!(target: "assertions", id = ?expected.id, "UDP reply payload does not match");
            }
        }
    }
}

fn assert_icmp_error_return(
    expected: &ExpectedProbe,
    injected: &ProbeEvent,
    returned: &ProbeEvent,
    expected_response: Option<RejectionResponse>,
) {
    assert_correct_src_and_dst_ips(&injected.packet, &returned.packet);

    let Ok(Some((failed_packet, error))) = returned.packet.icmp_error() else {
        tracing::error!(target: "assertions", id = ?expected.id, "Probe did not return an ICMP error");
        return;
    };

    if let Some(expected_response) = expected_response
        && rejection_response(&returned.packet) != Some(expected_response)
    {
        tracing::error!(target: "assertions", id = ?expected.id, ?expected_response, ?error, "Probe returned the wrong ICMP error");
    }

    if failed_packet.src() != injected.packet.source()
        || failed_packet.dst() != injected.packet.destination()
    {
        tracing::error!(target: "assertions", id = ?expected.id, "ICMP error quotes the wrong packet addresses");
    }

    let actual_protocol = failed_packet.layer4_protocol();
    let protocol_matches = match expected.request.probe_protocol() {
        ProbeProtocol::Icmp { seq, identifier } => matches!(
            actual_protocol,
            Layer4Protocol::Icmp {
                seq: actual_seq,
                id: actual_identifier,
            } if (actual_seq, actual_identifier) == (seq.0, identifier.0)
        ),
        ProbeProtocol::Udp { sport, dport } => matches!(
            actual_protocol,
            Layer4Protocol::Udp {
                src: actual_sport,
                dst: actual_dport,
            } if (actual_sport, actual_dport) == (sport.0, dport.0)
        ),
    };

    if !protocol_matches {
        tracing::error!(target: "assertions", id = ?expected.id, "ICMP error quotes the wrong transport tuple");
    }
}

fn assert_probe_payload(expected: ProbeId, packet: &IpPacket) {
    let Some(payload) = probe_payload(packet) else {
        tracing::error!(target: "assertions", ?expected, "Probe packet has no application payload");
        return;
    };

    if ProbeId::from_payload(payload) != Some(expected) {
        tracing::error!(target: "assertions", ?expected, "Probe packet carries the wrong ID");
    }
}

fn probe_payload(packet: &IpPacket) -> Option<&[u8]> {
    if let Some(udp) = packet.as_udp() {
        return Some(udp.payload());
    }
    if let Some(icmp) = packet.as_icmpv4() {
        return Some(icmp.payload());
    }
    if let Some(icmp) = packet.as_icmpv6() {
        return Some(icmp.payload());
    }

    None
}

fn icmp_echo_request(packet: &IpPacket) -> Option<(u16, u16, &[u8])> {
    if let Some(icmp) = packet.as_icmpv4()
        && let Icmpv4Type::EchoRequest(header) = icmp.icmp_type()
    {
        return Some((header.seq, header.id, icmp.payload()));
    }
    if let Some(icmp) = packet.as_icmpv6()
        && let Icmpv6Type::EchoRequest(header) = icmp.icmp_type()
    {
        return Some((header.seq, header.id, icmp.payload()));
    }

    None
}

fn icmp_echo_reply(packet: &IpPacket) -> Option<(u16, u16, &[u8])> {
    if let Some(icmp) = packet.as_icmpv4()
        && let Icmpv4Type::EchoReply(header) = icmp.icmp_type()
    {
        return Some((header.seq, header.id, icmp.payload()));
    }
    if let Some(icmp) = packet.as_icmpv6()
        && let Icmpv6Type::EchoReply(header) = icmp.icmp_type()
    {
        return Some((header.seq, header.id, icmp.payload()));
    }

    None
}

fn rejection_response(packet: &IpPacket) -> Option<RejectionResponse> {
    let (_, error) = packet.icmp_error().ok()??;

    if error.is_unreachable_prohibited() {
        return Some(RejectionResponse::Prohibited);
    }
    if error.is_unreachable_network() {
        return Some(RejectionResponse::Unreachable);
    }

    None
}

pub(crate) fn assert_tcp_connections(ref_client: &RefClient, sim_client: &SimClient) {
    for ((sport, dport), error) in &sim_client.failed_tcp_packets {
        let expected_rejection = ref_client
            .expected_tcp_rejections
            .contains_key(&(*sport, *dport));
        let expected_connection = ref_client.expected_tcp_connections.keys().any(
            |(_, _, expected_sport, expected_dport)| {
                (expected_sport, expected_dport) == (sport, dport)
            },
        );

        if !expected_rejection && !expected_connection {
            tracing::error!(target: "assertions", sport = sport.0, dport = dport.0, ?error, "Unexpected failed TCP connection");
        }
    }

    for ((sport, dport), response) in &ref_client.expected_tcp_rejections {
        match sim_client.failed_tcp_packets.get(&(*sport, *dport)) {
            Some(error)
                if match response {
                    RejectionResponse::Prohibited => error.is_unreachable_prohibited(),
                    RejectionResponse::Unreachable => error.is_unreachable_network(),
                } =>
            {
                tracing::info!(target: "assertions", sport = sport.0, dport = dport.0, "TCP connection was rejected as expected");
            }
            Some(error) => {
                tracing::error!(target: "assertions", sport = sport.0, dport = dport.0, ?response, ?error, "Received wrong ICMP error for rejected TCP connection");
            }
            None => {
                tracing::error!(target: "assertions", sport = sport.0, dport = dport.0, ?response, "Missing ICMP error for rejected TCP connection");
            }
        }
    }

    for (src, _, sport, dport) in ref_client.expected_tcp_connections.keys() {
        let src = SocketAddr::new(*src, sport.0);
        let received_icmp_error_for_tuple = sim_client.failed_tcp_packets.get(&(*sport, *dport));

        let Some((socket, local)) = sim_client.tcp_client.iter_sockets().find_map(|s| {
            let endpoint = s.local_endpoint()?;

            (l3_tcp::IpEndpoint::from(src) == endpoint).then_some((s, endpoint))
        }) else {
            if let Some(icmp_error) = received_icmp_error_for_tuple
                && icmp_error.is_unreachable_prohibited()
            {
                tracing::error!(target: "assertions", %src, port = %dport.0, "Received ICMP prohibited error for a TCP connection expected to reach the resource");
                continue;
            }

            if received_icmp_error_for_tuple.is_some() {
                continue;
            }

            tracing::error!(target: "assertions", %src, "Missing TCP connection");
            continue;
        };

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

fn assert_destination_is_ip(gateway_received_request: &IpPacket, expected: &IpAddr) {
    let actual = gateway_received_request.destination();

    if actual != *expected {
        tracing::error!(target: "assertions", %actual, %expected, "❌ Incorrect resource destination");
    } else {
        tracing::info!(target: "assertions", ip = %actual, "✅ Probe targets correct destination");
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
    fn max_level_hint(&self) -> Option<tracing::level_filters::LevelFilter> {
        Some(tracing::level_filters::LevelFilter::ERROR)
    }

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::probe::KnownLoss;

    #[test]
    fn exact_probe_trace_rejects_duplicate_delivery() {
        let (expected, mut events) = delivered_probe(TraceRequirement::Exact);
        let event_refs = events.iter().collect::<Vec<_>>();

        assert!(observed_trace(&expected, &event_refs).is_ok());

        events.push(events[1].clone());
        let event_refs = events.iter().collect::<Vec<_>>();

        assert_eq!(
            observed_trace(&expected, &event_refs).unwrap_err(),
            "delivered probe did not have exactly one delivery"
        );
    }

    #[test]
    fn optional_probe_trace_rejects_partial_delivery() {
        let (expected, mut events) = delivered_probe(TraceRequirement::ExactOrNoRemoteEvents(
            KnownLoss::ConnectionReset,
        ));
        events.truncate(1);
        let event_refs = events.iter().collect::<Vec<_>>();

        assert!(observed_trace(&expected, &event_refs).is_ok());

        let (_, full_trace) = delivered_probe(expected.trace_requirement);
        events.push(full_trace[1].clone());
        let event_refs = events.iter().collect::<Vec<_>>();

        assert_eq!(
            observed_trace(&expected, &event_refs).unwrap_err(),
            "delivered probe did not have exactly one return"
        );
    }

    fn delivered_probe(requirement: TraceRequirement) -> (ExpectedProbe, Vec<ProbeEvent>) {
        let id = ProbeId::new(1);
        let origin = ClientId::from_u128(2);
        let gateway = GatewayId::from_u128(3);
        let now = Instant::now();
        let source = "100.96.0.1".parse().unwrap();
        let destination = "10.0.0.1".parse().unwrap();
        let packet =
            ip_packet::make::udp_packet(source, destination, 40000, 443, &id.to_be_bytes())
                .unwrap();
        let expected = ExpectedProbe {
            id,
            origin,
            sent_at: now,
            request: ProbeRequest::Udp {
                src: source,
                dst: Destination::IpAddr(destination),
                sport: crate::transition::SPort(40000),
                dport: crate::transition::DPort(443),
            },
            outcome: ExpectedOutcome::Delivered {
                remote: Remote::Gateway(gateway),
                resource: None,
            },
            trace_requirement: requirement,
        };
        let events = vec![
            ProbeEvent {
                id,
                at: now,
                kind: ProbeEventKind::Injected { client: origin },
                packet: packet.clone(),
            },
            ProbeEvent {
                id,
                at: now,
                kind: ProbeEventKind::Delivered {
                    remote: Remote::Gateway(gateway),
                },
                packet: packet.clone(),
            },
            ProbeEvent {
                id,
                at: now,
                kind: ProbeEventKind::Returned { client: origin },
                packet,
            },
        ];

        (expected, events)
    }
}
