use super::{
    icmp_error_hosts::IcmpErrorHosts,
    probe::{
        ExpectedOutcome, ExpectedProbe, ProbeId, ProbeObservation, ProbeProtocol, ProbeRequest,
        ReceivedRequest, ReceivedResponse, RejectionResponse, Remote, SubmittedRequest,
        TraceRequirement,
    },
    ref_client::RefClient,
    sim_client::SimClient,
    sim_gateway::SimGateway,
    stub_portal::StubPortal,
    transition::Destination,
};
use connlib_model::{ClientId, GatewayId, ResourceId, ResourceStatus, ResourceView};
use ip_packet::{Icmpv4Type, Icmpv6Type, IpPacket, Layer4Protocol};
use itertools::Itertools;
use std::{
    collections::BTreeMap,
    iter,
    marker::PhantomData,
    net::{IpAddr, SocketAddr},
    sync::atomic::{AtomicBool, Ordering},
};
use tracing::{Level, Subscriber};
use tracing_subscriber::Layer;

/// Compares each expected application probe with all endpoint observations.
pub(crate) fn assert_probes(
    expected_probes: &BTreeMap<ProbeId, ExpectedProbe>,
    ref_clients: &BTreeMap<ClientId, &RefClient>,
    sim_clients: &BTreeMap<ClientId, &SimClient>,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
    icmp_error_hosts: &IcmpErrorHosts,
) {
    let observations = iter::empty()
        .chain(
            sim_clients
                .values()
                .flat_map(|client| client.probe_observations.iter()),
        )
        .chain(
            sim_gateways
                .values()
                .flat_map(|gateway| gateway.probe_observations.iter()),
        )
        .collect_vec();

    for id in observations
        .iter()
        .map(|observation| observation.id())
        .unique()
        .filter(|id| !expected_probes.contains_key(id))
    {
        tracing::error!(target: "assertions", ?id, "Unexpected probe observations");
    }

    for expected in expected_probes.values() {
        let probe_observations = observations
            .iter()
            .copied()
            .filter(|observation| observation.id() == expected.id)
            .collect_vec();
        let submissions = probe_observations
            .iter()
            .copied()
            .filter_map(ProbeObservation::as_submitted_request)
            .collect_vec();
        let received_requests = probe_observations
            .iter()
            .copied()
            .filter_map(ProbeObservation::as_received_request)
            .collect_vec();
        let received_responses = probe_observations
            .iter()
            .copied()
            .filter_map(ProbeObservation::as_received_response)
            .collect_vec();

        let [submitted_request] = submissions.as_slice() else {
            tracing::error!(target: "assertions", id = ?expected.id, ?probe_observations, "Probe does not have exactly one request submission");
            continue;
        };

        assert_submitted_request(expected, submitted_request);

        match (
            expected.trace_requirement,
            received_requests.as_slice(),
            received_responses.as_slice(),
        ) {
            (TraceRequirement::ExactOrSubmissionOnly(reason), [], []) => {
                tracing::debug!(target: "assertions", id = ?expected.id, ?reason, "Probe has only its request submission where loss is allowed");
                continue;
            }
            (TraceRequirement::Exact, _, _) => {}
            (TraceRequirement::ExactOrSubmissionOnly(_), _, _) => {}
        }

        match expected.outcome {
            ExpectedOutcome::Dropped => {
                let ([], []) = (received_requests.as_slice(), received_responses.as_slice()) else {
                    tracing::error!(target: "assertions", id = ?expected.id, ?probe_observations, "Dropped probe produced remote observations");
                    continue;
                };
            }
            ExpectedOutcome::RoundTripCompleted {
                remote: expected_remote,
                ..
            } => {
                let ([received_request], [received_response]) =
                    (received_requests.as_slice(), received_responses.as_slice())
                else {
                    tracing::error!(target: "assertions", id = ?expected.id, ?probe_observations, "Completed round trip does not have exactly one received request and one received response");
                    continue;
                };

                if received_request.remote != expected_remote {
                    tracing::error!(target: "assertions", id = ?expected.id, ?expected_remote, actual = ?received_request.remote, "Probe request was received by the wrong remote");
                }
                if received_response.client != expected.origin {
                    tracing::error!(target: "assertions", id = ?expected.id, expected = ?expected.origin, actual = ?received_response.client, "Probe response was received by the wrong client");
                }

                assert_received_request(
                    expected,
                    submitted_request,
                    received_request,
                    ref_clients,
                    sim_gateways,
                );
                assert_received_response(
                    expected,
                    submitted_request,
                    received_request,
                    received_response,
                    expected_remote,
                    icmp_error_hosts,
                );
            }
            ExpectedOutcome::Rejected { response, .. } => {
                let ([], [received_response]) =
                    (received_requests.as_slice(), received_responses.as_slice())
                else {
                    tracing::error!(target: "assertions", id = ?expected.id, ?probe_observations, "Rejected probe does not have exactly one received response and no received requests");
                    continue;
                };

                if received_response.client != expected.origin {
                    tracing::error!(target: "assertions", id = ?expected.id, expected = ?expected.origin, actual = ?received_response.client, "Rejection response was received by the wrong client");
                }

                assert_icmp_error_response(
                    expected,
                    submitted_request,
                    received_response,
                    Some(response),
                );
            }
        }
    }
}

fn assert_submitted_request(expected: &ExpectedProbe, submitted_request: &SubmittedRequest) {
    if submitted_request.client != expected.origin {
        tracing::error!(target: "assertions", id = ?expected.id, expected = ?expected.origin, actual = ?submitted_request.client, "Probe request was submitted by the wrong client");
    }

    if submitted_request.at != expected.sent_at {
        tracing::error!(target: "assertions", id = ?expected.id, "Probe request was submitted at the wrong time");
    }

    if submitted_request.packet.source() != expected.request.source() {
        tracing::error!(target: "assertions", id = ?expected.id, "Submitted request has the wrong source");
    }

    if let Destination::IpAddr(expected_destination) = expected.request.destination()
        && submitted_request.packet.destination() != *expected_destination
    {
        tracing::error!(target: "assertions", id = ?expected.id, "Submitted request has the wrong destination");
    }

    assert_probe_payload(expected.id, &submitted_request.packet);

    match &expected.request {
        ProbeRequest::Icmp {
            seq, identifier, ..
        } => match icmp_echo_request(&submitted_request.packet) {
            Some((actual_seq, actual_identifier, _)) => {
                if (actual_seq, actual_identifier) != (seq.0, identifier.0) {
                    tracing::error!(target: "assertions", id = ?expected.id, "ICMP probe identifiers do not match");
                }
            }
            None => {
                tracing::error!(target: "assertions", id = ?expected.id, "Submitted probe request is not an ICMP echo request");
            }
        },
        ProbeRequest::Udp { sport, dport, .. } => match submitted_request.packet.as_udp() {
            Some(udp) => {
                if (udp.source_port(), udp.destination_port()) != (sport.0, dport.0) {
                    tracing::error!(target: "assertions", id = ?expected.id, "UDP probe ports do not match");
                }
            }
            None => {
                tracing::error!(target: "assertions", id = ?expected.id, "Submitted probe request is not UDP");
            }
        },
    }
}

fn assert_received_request(
    expected: &ExpectedProbe,
    submitted_request: &SubmittedRequest,
    received_request: &ReceivedRequest,
    ref_clients: &BTreeMap<ClientId, &RefClient>,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
) {
    assert_probe_payload(expected.id, &received_request.packet);

    if probe_payload(&submitted_request.packet) != probe_payload(&received_request.packet) {
        tracing::error!(target: "assertions", id = ?expected.id, "Probe payload changed in transit");
    }

    let ref_client = ref_clients.get(&expected.origin).unwrap();
    let expected_source = ref_client.tunnel_ip_for(received_request.packet.source());
    if received_request.packet.source() != expected_source {
        tracing::error!(target: "assertions", id = ?expected.id, "Received request has the wrong source");
    }

    match expected.request.destination() {
        Destination::IpAddr(destination) => {
            assert_destination_is_ip(&received_request.packet, destination);
        }
        Destination::DomainName { name, .. } => {
            let gateway = match received_request.remote {
                Remote::Gateway(gateway) => gateway,
                Remote::Client(_) => {
                    tracing::error!(target: "assertions", id = ?expected.id, "DNS probe request was not received through a gateway");
                    return;
                }
            };
            let Some(possible_resource_ips) = sim_gateways.get(&gateway).and_then(|gateway| {
                gateway
                    .dns_resolutions
                    .get(&(expected.origin, name.clone()))
            }) else {
                tracing::error!(target: "assertions", id = ?expected.id, "DNS probe has no gateway resolution");
                return;
            };

            assert_destination_is_dns_resource(
                &received_request.packet,
                name,
                possible_resource_ips,
            );
        }
    }
}

fn assert_received_response(
    expected: &ExpectedProbe,
    submitted_request: &SubmittedRequest,
    received_request: &ReceivedRequest,
    received_response: &ReceivedResponse,
    remote: Remote,
    icmp_error_hosts: &IcmpErrorHosts,
) {
    if remote_responds_with_icmp_error(expected, received_request, remote, icmp_error_hosts) {
        assert_icmp_error_response(expected, submitted_request, received_response, None);
        return;
    }

    assert_echo_response(expected, submitted_request, received_response);
}

fn remote_responds_with_icmp_error(
    expected: &ExpectedProbe,
    received_request: &ReceivedRequest,
    remote: Remote,
    icmp_error_hosts: &IcmpErrorHosts,
) -> bool {
    let is_icmp_peer = match (&expected.request, remote) {
        (ProbeRequest::Icmp { .. }, Remote::Gateway(_)) => false,
        (ProbeRequest::Icmp { .. }, Remote::Client(_)) => true,
        (ProbeRequest::Udp { .. }, Remote::Gateway(_)) => false,
        (ProbeRequest::Udp { .. }, Remote::Client(_)) => false,
    };

    !is_icmp_peer
        && icmp_error_hosts
            .icmp_error_for_ip(received_request.packet.destination())
            .is_some()
}

fn assert_echo_response(
    expected: &ExpectedProbe,
    submitted_request: &SubmittedRequest,
    received_response: &ReceivedResponse,
) {
    assert_correct_src_and_dst_ips(&submitted_request.packet, &received_response.packet);

    match &expected.request {
        ProbeRequest::Icmp { .. } => match (
            icmp_echo_request(&submitted_request.packet),
            icmp_echo_reply(&received_response.packet),
        ) {
            (
                Some((request_seq, request_identifier, request_payload)),
                Some((reply_seq, reply_identifier, reply_payload)),
            ) => {
                if (request_seq, request_identifier) != (reply_seq, reply_identifier) {
                    tracing::error!(target: "assertions", id = ?expected.id, "ICMP reply identifiers do not match");
                }
                if request_payload != reply_payload {
                    tracing::error!(target: "assertions", id = ?expected.id, "ICMP reply payload does not match");
                }
            }
            (None, Some(_)) => {
                tracing::error!(target: "assertions", id = ?expected.id, "Submitted probe request is not an ICMP echo request");
            }
            (Some(_), None) => {
                tracing::error!(target: "assertions", id = ?expected.id, "Received probe response is not an ICMP echo reply");
            }
            (None, None) => {
                tracing::error!(target: "assertions", id = ?expected.id, "Submitted probe request is not an ICMP echo request");
                tracing::error!(target: "assertions", id = ?expected.id, "Received probe response is not an ICMP echo reply");
            }
        },
        ProbeRequest::Udp { .. } => {
            match (
                submitted_request.packet.as_udp(),
                received_response.packet.as_udp(),
            ) {
                (Some(request), Some(reply)) => {
                    assert_correct_src_and_dst_udp_ports(
                        &submitted_request.packet,
                        &received_response.packet,
                    );

                    if request.payload() != reply.payload() {
                        tracing::error!(target: "assertions", id = ?expected.id, "UDP reply payload does not match");
                    }
                }
                (None, Some(_)) => {
                    tracing::error!(target: "assertions", id = ?expected.id, "Submitted probe request is not UDP");
                }
                (Some(_), None) => {
                    tracing::error!(target: "assertions", id = ?expected.id, "Received probe response is not UDP");
                }
                (None, None) => {
                    tracing::error!(target: "assertions", id = ?expected.id, "Submitted probe request is not UDP");
                    tracing::error!(target: "assertions", id = ?expected.id, "Received probe response is not UDP");
                }
            }
        }
    }
}

fn assert_icmp_error_response(
    expected: &ExpectedProbe,
    submitted_request: &SubmittedRequest,
    received_response: &ReceivedResponse,
    expected_response: Option<RejectionResponse>,
) {
    assert_correct_src_and_dst_ips(&submitted_request.packet, &received_response.packet);

    let Ok(Some((failed_packet, error))) = received_response.packet.icmp_error() else {
        tracing::error!(target: "assertions", id = ?expected.id, "Received probe response is not an ICMP error");
        return;
    };

    if let Some(expected_response) = expected_response
        && rejection_response(&received_response.packet) != Some(expected_response)
    {
        tracing::error!(target: "assertions", id = ?expected.id, ?expected_response, ?error, "Received probe response contains the wrong ICMP error");
    }

    if failed_packet.src() != submitted_request.packet.source()
        || failed_packet.dst() != submitted_request.packet.destination()
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

        // Several sockets can share a local endpoint (one port, several remotes),
        // so the remote port is needed to pick the right connection.
        let Some((socket, local, remote)) = sim_client.tcp_client.iter_sockets().find_map(|s| {
            let local = s.local_endpoint()?;
            let remote = s.remote_endpoint()?;

            (l3_tcp::IpEndpoint::from(src) == local && remote.port == dport.0)
                .then_some((s, local, remote))
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

pub(crate) fn assert_resource_list(ref_client: &RefClient, sim_client: &SimClient) {
    let expected_resources = ref_client.expected_resources();
    let actual_resources = &sim_client.observed_resource_list.resources;
    let maybe_online_resources = ref_client.maybe_online_resources();
    let expected_ids = expected_resources
        .iter()
        .map(ResourceView::id)
        .collect_vec();
    let actual_ids = actual_resources.iter().map(ResourceView::id).collect_vec();

    if expected_ids != actual_ids {
        tracing::error!(target: "assertions", ?expected_ids, ?actual_ids, "Resource list order or membership doesn't match");
    }

    let actual_by_id = actual_resources
        .iter()
        .map(|resource| (resource.id(), resource))
        .collect::<BTreeMap<_, _>>();

    for expected in &expected_resources {
        let resource = expected.id();
        let Some(actual) = actual_by_id.get(&resource) else {
            tracing::error!(target: "assertions", %resource, "Missing resource");
            continue;
        };

        assert_resource_definition(expected, actual);
        assert_resource_status(
            resource,
            expected.status(),
            actual.status(),
            maybe_online_resources.contains(&resource),
        );
    }

    for actual in actual_resources {
        if !expected_ids.contains(&actual.id()) {
            tracing::error!(target: "assertions", resource = %actual.id(), "Unexpected resource");
        }
    }
}

fn assert_resource_definition(expected: &ResourceView, actual: &ResourceView) {
    use ResourceView::*;

    let resource = expected.id();

    match (expected, actual) {
        (Dns(expected), Dns(actual)) => {
            assert_resource_field(resource, "address", &expected.address, &actual.address);
            assert_resource_field(resource, "name", &expected.name, &actual.name);
            assert_resource_field(
                resource,
                "address description",
                &expected.address_description,
                &actual.address_description,
            );
            assert_resource_field(resource, "sites", &expected.sites, &actual.sites);
        }
        (Cidr(expected), Cidr(actual)) => {
            assert_resource_field(resource, "address", &expected.address, &actual.address);
            assert_resource_field(resource, "name", &expected.name, &actual.name);
            assert_resource_field(
                resource,
                "address description",
                &expected.address_description,
                &actual.address_description,
            );
            assert_resource_field(resource, "sites", &expected.sites, &actual.sites);
        }
        (Internet(expected), Internet(actual)) => {
            assert_resource_field(resource, "name", &expected.name, &actual.name);
            assert_resource_field(resource, "sites", &expected.sites, &actual.sites);
        }
        (Dns(_), Cidr(_)) => {
            tracing::error!(target: "assertions", %resource, "DNS resource was emitted as a CIDR resource");
        }
        (Dns(_), Internet(_)) => {
            tracing::error!(target: "assertions", %resource, "DNS resource was emitted as an Internet resource");
        }
        (Cidr(_), Dns(_)) => {
            tracing::error!(target: "assertions", %resource, "CIDR resource was emitted as a DNS resource");
        }
        (Cidr(_), Internet(_)) => {
            tracing::error!(target: "assertions", %resource, "CIDR resource was emitted as an Internet resource");
        }
        (Internet(_), Dns(_)) => {
            tracing::error!(target: "assertions", %resource, "Internet resource was emitted as a DNS resource");
        }
        (Internet(_), Cidr(_)) => {
            tracing::error!(target: "assertions", %resource, "Internet resource was emitted as a CIDR resource");
        }
    }
}

fn assert_resource_field<T>(resource: ResourceId, field: &str, expected: &T, actual: &T)
where
    T: std::fmt::Debug + PartialEq,
{
    if expected != actual {
        tracing::error!(target: "assertions", %resource, field, ?expected, ?actual, "Resource field doesn't match");
    }
}

fn assert_resource_status(
    resource: ResourceId,
    expected: ResourceStatus,
    actual: ResourceStatus,
    maybe_online: bool,
) {
    use ResourceStatus::*;

    match (expected, actual) {
        (Unknown, Unknown) => {}
        (Unknown, Online) if maybe_online => {}
        (Unknown, Online) => {
            tracing::error!(target: "assertions", %expected, %actual, %resource, "Resource status doesn't match");
        }
        (Unknown, Offline) => {
            tracing::error!(target: "assertions", %expected, %actual, %resource, "Resource status doesn't match");
        }
        (Online, Unknown) if maybe_online => {}
        (Online, Unknown) => {
            tracing::error!(target: "assertions", %expected, %actual, %resource, "Resource status doesn't match");
        }
        (Online, Online) => {}
        (Online, Offline) => {
            tracing::error!(target: "assertions", %expected, %actual, %resource, "Resource status doesn't match");
        }
        (Offline, Unknown) => {
            tracing::error!(target: "assertions", %expected, %actual, %resource, "Resource status doesn't match");
        }
        (Offline, Online) => {
            tracing::error!(target: "assertions", %expected, %actual, %resource, "Resource status doesn't match");
        }
        (Offline, Offline) => {}
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
    let unexpected_dns_replies = sim_client
        .received_udp_dns_responses
        .keys()
        .filter(|response| !ref_client.expected_udp_dns_handshakes.contains(response))
        .collect_vec();

    if !unexpected_dns_replies.is_empty() {
        tracing::error!(target: "assertions", ?unexpected_dns_replies, "❌ Unexpected UDP DNS replies on client");
    }

    for (dns_server, query_id, local_port) in ref_client.expected_udp_dns_handshakes.iter() {
        let _guard =
            tracing::info_span!(target: "assertions", "udp_dns", %query_id, %dns_server).entered();
        let key = &(dns_server.clone(), *query_id, *local_port);

        let queries = &sim_client.sent_udp_dns_queries;
        let responses = &sim_client.received_udp_dns_responses;

        match (queries.get(key), responses.get(key)) {
            (Some(client_sent_query), Some(client_received_response)) => {
                assert_correct_src_and_dst_ips(client_sent_query, client_received_response);
                assert_correct_src_and_dst_udp_ports(client_sent_query, client_received_response);
            }
            (Some(_), None) => {
                tracing::error!(target: "assertions", ?responses, "❌ Missing UDP DNS response on client");
            }
            (None, Some(_)) => {
                tracing::error!(target: "assertions", ?queries, "❌ Missing UDP DNS query on client");
            }
            (None, None) => {
                tracing::error!(target: "assertions", ?queries, "❌ Missing UDP DNS query on client");
                tracing::error!(target: "assertions", ?responses, "❌ Missing UDP DNS response on client");
            }
        }
    }
}

pub(crate) fn assert_tcp_dns(ref_client: &RefClient, sim_client: &SimClient) {
    let unexpected_dns_responses = sim_client
        .received_tcp_dns_responses
        .iter()
        .filter(|response| !ref_client.expected_tcp_dns_handshakes.contains(response))
        .collect_vec();

    if !unexpected_dns_responses.is_empty() {
        tracing::error!(target: "assertions", ?unexpected_dns_responses, "❌ Unexpected TCP DNS responses on client");
    }

    for (dns_server, query_id) in ref_client.expected_tcp_dns_handshakes.iter() {
        let _guard =
            tracing::info_span!(target: "assertions", "tcp_dns", %query_id, %dns_server).entered();
        let key = &(dns_server.clone(), *query_id);

        let queries = &sim_client.sent_tcp_dns_queries;
        let responses = &sim_client.received_tcp_dns_responses;

        match (queries.contains(key), responses.contains(key)) {
            (true, true) => {}
            (true, false) => {
                tracing::error!(target: "assertions", ?responses, "❌ Missing TCP DNS response on client");
            }
            (false, true) => {
                tracing::error!(target: "assertions", ?queries, "❌ Missing TCP DNS query on client");
            }
            (false, false) => {
                tracing::error!(target: "assertions", ?queries, "❌ Missing TCP DNS query on client");
                tracing::error!(target: "assertions", ?responses, "❌ Missing TCP DNS response on client");
            }
        }
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
    domain: &dns_types::DomainName,
    possible_resource_ips: &[IpAddr],
) {
    let actual = gateway_received_request.destination();

    if !possible_resource_ips.contains(&actual) {
        tracing::error!(target: "assertions", %domain, %actual, ?possible_resource_ips, "❌ Unknown resource IP");
    } else {
        tracing::info!(target: "assertions", %domain, ip = %actual, "✅ Resource IP is valid");
    }
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
