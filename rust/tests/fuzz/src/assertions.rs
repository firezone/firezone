use crate::ref_gateway::RefGateway;

use super::{
    dns_records::DnsRecords,
    ref_client::{
        ExpectedHandshakes, ExpectedRejection, RefClient, RejectionRemote, RejectionResponse,
    },
    sim_client::SimClient,
    sim_gateway::SimGateway,
    stub_portal::StubPortal,
    transition::{DPort, Destination, Identifier, ReplyTo, SPort, Seq},
};
use connlib_model::{ClientId, GatewayId};
use ip_packet::IpPacket;
use itertools::Itertools;
use std::{
    collections::{BTreeMap, BTreeSet, HashMap, hash_map::Entry},
    fmt,
    hash::Hash,
    iter,
    marker::PhantomData,
    net::{IpAddr, SocketAddr},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};
use tracing::{Level, Span, Subscriber};
use tracing_subscriber::Layer;

/// Minimum idle time on a client→gateway connection before we tolerate a single
/// dropped packet caused by a WireGuard re-key.
///
/// This is a *threshold*, not the width of the dead window. A session is usable
/// for `REJECT_AFTER_TIME - KEEPALIVE_TIMEOUT` (170s); it then spends the
/// remaining `KEEPALIVE_TIMEOUT` (10s) in a "dead window" where it is no longer
/// usable but, while idle, is not re-keyed until it fully expires at
/// `REJECT_AFTER_TIME` (180s). A packet sent in that ~10s dead window hits
/// `NoCurrentSession` in the side-effect-free `encapsulate_data_at` path and is
/// dropped without being re-queued; the connection re-keys ~1 RTT later, so only
/// the triggering packet is lost. The dead window recurs every
/// `REJECT_AFTER_TIME` while idle, so any packet sent at least one usable
/// session lifetime (this threshold) after the previous one on the same
/// connection may land in it. See #13957.
const MIN_IDLE_FOR_REKEY_DROP: Duration = Duration::from_secs(180 - 10);

/// A protocol whose request / reply handshakes we track end-to-end.
///
/// ICMP and UDP handshakes follow the same pattern:
/// The client sends a request that is either echoed back by the destination, answered with an ICMP error or dropped.
/// Implementations of this trait bundle the per-protocol bookkeeping of [`RefClient`], [`SimClient`] and [`SimGateway`]
/// so [`assert_packets_properties`] can assert both protocols with the same logic.
trait EchoProtocol {
    const NAME: &'static str;

    /// Identifies a request (and via [`ReplyTo`] its reply) from the sending client's perspective.
    type FlowId: ReplyTo + Copy + fmt::Debug + Hash + Eq + Ord;

    fn sent_requests(client: &SimClient) -> &BTreeMap<Self::FlowId, (Instant, IpPacket)>;
    fn received_replies(client: &SimClient) -> &BTreeMap<Self::FlowId, IpPacket>;
    fn received_requests_on_client(client: &SimClient) -> &BTreeMap<u64, (Instant, IpPacket)>;
    fn received_requests_on_gateway(gateway: &SimGateway) -> &BTreeMap<u64, (Instant, IpPacket)>;
    fn expected_gateway_handshakes(
        client: &RefClient,
    ) -> &BTreeMap<GatewayId, ExpectedHandshakes<Self::FlowId>>;
    fn expected_client_handshakes(
        client: &RefClient,
    ) -> &BTreeMap<ClientId, ExpectedHandshakes<Self::FlowId>>;
    fn expected_rejections(client: &RefClient) -> &BTreeMap<Self::FlowId, ExpectedRejection>;

    /// Extracts the payload that the remote echoes back to the sender.
    fn payload(packet: &IpPacket) -> Option<&[u8]>;
    fn span(flow: Self::FlowId) -> Span;
}

enum Icmp {}

impl EchoProtocol for Icmp {
    const NAME: &'static str = "ICMP";
    type FlowId = (Seq, Identifier);

    fn sent_requests(client: &SimClient) -> &BTreeMap<Self::FlowId, (Instant, IpPacket)> {
        &client.sent_icmp_requests
    }
    fn received_replies(client: &SimClient) -> &BTreeMap<Self::FlowId, IpPacket> {
        &client.received_icmp_replies
    }
    fn received_requests_on_client(client: &SimClient) -> &BTreeMap<u64, (Instant, IpPacket)> {
        &client.received_icmp_requests
    }
    fn received_requests_on_gateway(gateway: &SimGateway) -> &BTreeMap<u64, (Instant, IpPacket)> {
        &gateway.received_icmp_requests
    }
    fn expected_gateway_handshakes(
        client: &RefClient,
    ) -> &BTreeMap<GatewayId, ExpectedHandshakes<Self::FlowId>> {
        &client.expected_gateway_icmp_handshakes
    }
    fn expected_client_handshakes(
        client: &RefClient,
    ) -> &BTreeMap<ClientId, ExpectedHandshakes<Self::FlowId>> {
        &client.expected_client_icmp_handshakes
    }
    fn expected_rejections(client: &RefClient) -> &BTreeMap<Self::FlowId, ExpectedRejection> {
        &client.expected_icmp_rejections
    }
    fn payload(packet: &IpPacket) -> Option<&[u8]> {
        packet
            .as_icmpv4()
            .map(|icmp| icmp.payload())
            .or_else(|| packet.as_icmpv6().map(|icmp| icmp.payload()))
    }
    fn span((seq, identifier): Self::FlowId) -> Span {
        tracing::info_span!(target: "assertions", "ICMP", ?seq, ?identifier)
    }
}

enum Udp {}

impl EchoProtocol for Udp {
    const NAME: &'static str = "UDP";
    type FlowId = (SPort, DPort);

    fn sent_requests(client: &SimClient) -> &BTreeMap<Self::FlowId, (Instant, IpPacket)> {
        &client.sent_udp_requests
    }
    fn received_replies(client: &SimClient) -> &BTreeMap<Self::FlowId, IpPacket> {
        &client.received_udp_replies
    }
    fn received_requests_on_client(client: &SimClient) -> &BTreeMap<u64, (Instant, IpPacket)> {
        &client.received_udp_requests
    }
    fn received_requests_on_gateway(gateway: &SimGateway) -> &BTreeMap<u64, (Instant, IpPacket)> {
        &gateway.received_udp_requests
    }
    fn expected_gateway_handshakes(
        client: &RefClient,
    ) -> &BTreeMap<GatewayId, ExpectedHandshakes<Self::FlowId>> {
        &client.expected_gateway_udp_handshakes
    }
    fn expected_client_handshakes(
        client: &RefClient,
    ) -> &BTreeMap<ClientId, ExpectedHandshakes<Self::FlowId>> {
        &client.expected_client_udp_handshakes
    }
    fn expected_rejections(client: &RefClient) -> &BTreeMap<Self::FlowId, ExpectedRejection> {
        &client.expected_udp_rejections
    }
    fn payload(packet: &IpPacket) -> Option<&[u8]> {
        packet.as_udp().map(|udp| udp.payload())
    }
    fn span((sport, dport): Self::FlowId) -> Span {
        tracing::info_span!(target: "assertions", "UDP", ?sport, ?dport)
    }
}

/// Asserts the properties of all ICMP handshakes; see [`assert_packets_properties`].
pub(crate) fn assert_icmp_packets_properties(
    ref_clients: &BTreeMap<ClientId, &RefClient>,
    ref_gateways: &BTreeMap<GatewayId, &RefGateway>,
    sim_clients: &BTreeMap<ClientId, &SimClient>,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
    global_dns_records: &DnsRecords,
) {
    assert_packets_properties::<Icmp>(
        ref_clients,
        ref_gateways,
        sim_clients,
        sim_gateways,
        global_dns_records,
    );
}

/// Asserts the properties of all UDP handshakes; see [`assert_packets_properties`].
pub(crate) fn assert_udp_packets_properties(
    ref_clients: &BTreeMap<ClientId, &RefClient>,
    ref_gateways: &BTreeMap<GatewayId, &RefGateway>,
    sim_clients: &BTreeMap<ClientId, &SimClient>,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
    global_dns_records: &DnsRecords,
) {
    assert_packets_properties::<Udp>(
        ref_clients,
        ref_gateways,
        sim_clients,
        sim_gateways,
        global_dns_records,
    );
}

/// Asserts the following properties for all handshakes of the given protocol:
///
/// 1. A request expected to be rejected MUST be answered with the expected ICMP error (or tolerably dropped).
/// 2. A reply received by a client MUST correspond to a request that same client sent and use the flipped src & dst IP (and ports for UDP, via the flow ID).
/// 3. A successful reply MUST echo the request's payload.
/// 4. A request arriving at a gateway MUST target the intended resource:
///     - For CIDR resources, that is the actual CIDR resource IP.
///     - For DNS resources, the IP must match one of the IPs the domain resolved to at the time.
/// 5. For DNS resources, the mapping of proxy IP to actual resource IP must be stable.
/// 6. A request arriving at a gateway or peer client MUST have been predicted by the reference model, and vice versa.
fn assert_packets_properties<P: EchoProtocol>(
    ref_clients: &BTreeMap<ClientId, &RefClient>,
    ref_gateways: &BTreeMap<GatewayId, &RefGateway>,
    sim_clients: &BTreeMap<ClientId, &SimClient>,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
    global_dns_records: &DnsRecords,
) {
    let protocol = P::NAME;

    let all_sent_requests = sim_clients
        .iter()
        .flat_map(|(cid, sim_client)| {
            P::sent_requests(sim_client)
                .iter()
                .map(move |(flow, request)| ((*cid, *flow), request.clone()))
        })
        .collect::<BTreeMap<_, _>>();

    let all_received_replies = sim_clients
        .iter()
        .flat_map(|(cid, sim_client)| {
            P::received_replies(sim_client)
                .iter()
                .map(move |(flow, reply)| ((*cid, *flow), reply.clone()))
        })
        .collect::<BTreeMap<_, _>>();

    // Rejections are keyed by the flow ID of the ICMP error we expect to receive, i.e. the reply.
    let all_expected_rejections = ref_clients
        .iter()
        .flat_map(|(cid, ref_client)| {
            P::expected_rejections(ref_client)
                .iter()
                .map(move |(flow, rejection)| ((*cid, flow.reply_to()), *rejection))
        })
        .collect::<BTreeMap<_, _>>();

    let expected_gateway_handshakes =
        merge_expected_handshakes(ref_clients, P::expected_gateway_handshakes);
    let expected_client_handshakes =
        merge_expected_handshakes(ref_clients, P::expected_client_handshakes);

    for ((cid, reply_flow), rejection) in &all_expected_rejections {
        let Some(reply) = all_received_replies.get(&(*cid, *reply_flow)) else {
            let Some((sent_at, _)) = all_sent_requests.get(&(*cid, reply_flow.reply_to())) else {
                tracing::error!(target: "assertions", %cid, ?reply_flow, "❌ Missing rejected {protocol} request on client");
                continue;
            };
            let ref_client = ref_clients.get(cid).unwrap();

            if can_drop_during_rekey(ref_client, rejection.remote, *sent_at) {
                tracing::debug!(target: "assertions", %cid, remote = ?rejection.remote, "Tolerating rejected {protocol} packet dropped in the WireGuard re-key window");
                continue;
            }

            tracing::error!(target: "assertions", %cid, ?reply_flow, response = ?rejection.response, "❌ Missing ICMP error for rejected {protocol} packet");
            continue;
        };

        if rejection_response(reply) != Some(rejection.response) {
            tracing::error!(target: "assertions", %cid, ?reply_flow, response = ?rejection.response, "❌ Received wrong ICMP error for rejected {protocol} packet");
        }
    }

    // Rejected packets are not handshakes, so their ICMP errors were validated
    // above; exclude them before comparing successful replies below.
    let received_replies_excluding_rejections = all_received_replies
        .iter()
        .filter(|(key, reply)| {
            if all_expected_rejections.contains_key(*key) {
                return false;
            }

            if rejection_response(reply) == Some(RejectionResponse::Prohibited) {
                tracing::error!(target: "assertions", ?key, "❌ Unexpected ICMP error for {protocol} packet");

                return false;
            }

            true
        })
        .map(|(key, reply)| (*key, reply.clone()))
        .collect::<BTreeMap<_, _>>();

    // A reply must belong to a request for which the same client expects an answer.
    let expected_reply_flows = iter::empty()
        .chain(expected_gateway_handshakes.values().flatten())
        .chain(expected_client_handshakes.values().flatten())
        .map(|(_, (cid, _, flow))| (*cid, flow.reply_to()))
        .collect::<BTreeSet<_>>();

    for (key @ (cid, flow), reply) in &received_replies_excluding_rejections {
        if !expected_reply_flows.contains(key) {
            tracing::error!(target: "assertions", %cid, ?flow, ?reply, "❌ Unexpected {protocol} reply on client");
        }
    }

    assert_gateway_handshakes::<P>(
        &expected_gateway_handshakes,
        ref_clients,
        ref_gateways,
        sim_gateways,
        &all_sent_requests,
        &all_received_replies,
        global_dns_records,
    );
    assert_client_handshakes::<P>(
        &expected_client_handshakes,
        ref_clients,
        sim_clients,
        &all_sent_requests,
        &all_received_replies,
    );
}

/// Merges the per-client handshake expectations into a single map per remote, tagging each entry with the sending client.
fn merge_expected_handshakes<ID, F>(
    ref_clients: &BTreeMap<ClientId, &RefClient>,
    expected_handshakes: impl Fn(&RefClient) -> &BTreeMap<ID, ExpectedHandshakes<F>>,
) -> BTreeMap<ID, BTreeMap<u64, (ClientId, Destination, F)>>
where
    ID: Copy + Ord,
    F: Copy,
{
    let mut merged: BTreeMap<ID, BTreeMap<u64, (ClientId, Destination, F)>> = BTreeMap::new();

    for (cid, ref_client) in ref_clients {
        for (remote, handshakes) in expected_handshakes(ref_client) {
            for (payload, (destination, flow)) in handshakes {
                merged
                    .entry(*remote)
                    .or_default()
                    .insert(*payload, (*cid, destination.clone(), *flow));
            }
        }
    }

    merged
}

/// Asserts the handshakes between clients and gateways.
///
/// Due to connlib's implementation of NAT64, we cannot match the packets sent by the client to the packets arriving at the resource by port or ICMP identifier.
/// Thus, we rely on a custom u64 payload attached to all packets to uniquely identify every individual packet.
fn assert_gateway_handshakes<P: EchoProtocol>(
    expected_handshakes_by_gateway: &BTreeMap<
        GatewayId,
        BTreeMap<u64, (ClientId, Destination, P::FlowId)>,
    >,
    ref_clients: &BTreeMap<ClientId, &RefClient>,
    ref_gateways: &BTreeMap<GatewayId, &RefGateway>,
    sim_gateways: &BTreeMap<GatewayId, &SimGateway>,
    sent_requests: &BTreeMap<(ClientId, P::FlowId), (Instant, IpPacket)>,
    received_replies: &BTreeMap<(ClientId, P::FlowId), IpPacket>,
    global_dns_records: &DnsRecords,
) {
    let protocol = P::NAME;

    for gateway in expected_handshakes_by_gateway.keys() {
        if !ref_gateways.contains_key(gateway) {
            tracing::error!(target: "assertions", %gateway, "❌ Unknown Gateway");
        }
    }

    // The proxy IP mapping must be stable per client and DNS record snapshot; see `assert_proxy_ip_mapping_is_stable`.
    let mut proxy_ip_mappings = HashMap::new();

    for (gateway, sim_gateway) in sim_gateways {
        let expected_handshakes = expected_handshakes_by_gateway.get(gateway);
        let received_requests = P::received_requests_on_gateway(sim_gateway);

        let mut num_expected_handshakes = expected_handshakes.map_or(0, |e| e.len());

        for (payload, (cid, resource_dst, flow)) in expected_handshakes.into_iter().flatten() {
            let _guard = P::span(*flow).entered();

            let ref_client = ref_clients.get(cid).unwrap();

            let Some((sent_at, client_sent_request)) = sent_requests.get(&(*cid, *flow)) else {
                tracing::error!(target: "assertions", %cid, "❌ Missing {protocol} request on client");
                continue;
            };
            let Some(client_received_reply) = received_replies.get(&(*cid, flow.reply_to())) else {
                // A client→gateway connection that was idle long enough for its
                // WireGuard session to enter the re-key dead window drops this
                // one packet without a reply (see `MIN_IDLE_FOR_REKEY_DROP`). Tolerate
                // it when the previous packet on this connection was sent at
                // least `MIN_IDLE_FOR_REKEY_DROP` earlier.
                //
                // Only packets routed through `on_packet` are recorded, so a client
                // whose connection was established by other traffic (a DNS resource
                // query, say) has no previous packet at all. That cannot rule the
                // dead window out either, and a genuinely new connection buffers
                // rather than drops (`snownet::StillConnecting`), so treat a missing
                // record the same as a long-idle one.
                //
                // TODO: Delete once ICEless is the default.
                if can_drop_during_rekey(ref_client, RejectionRemote::Gateway(*gateway), *sent_at) {
                    tracing::debug!(target: "assertions", %cid, "Tolerating {protocol} packet dropped in the WireGuard re-key window");
                    num_expected_handshakes -= 1;
                    continue;
                }

                tracing::error!(target: "assertions", %cid, "❌ Missing {protocol} reply on client");
                continue;
            };
            assert_correct_src_and_dst_ips(client_sent_request, client_received_reply);
            assert_reply_echoes_payload::<P>(client_sent_request, client_received_reply);

            let Some((request_received_at, gateway_received_request)) =
                received_requests.get(payload)
            else {
                if let Ok(Some((_, icmp_error))) = client_received_reply.icmp_error()
                    && icmp_error.is_unreachable_prohibited()
                {
                    tracing::error!(target: "assertions", %cid, "❌ Received ICMP prohibited error for a packet expected to reach the resource");
                    continue;
                }

                if client_received_reply
                    .icmp_error()
                    .is_ok_and(|e| e.is_some())
                {
                    num_expected_handshakes -= 1;
                    continue;
                }

                tracing::error!(target: "assertions", %cid, "❌ Missing {protocol} request on gateway");
                continue;
            };

            {
                let expected = ref_client.tunnel_ip_for(gateway_received_request.source());
                let actual = gateway_received_request.source();

                if expected != actual {
                    tracing::error!(target: "assertions", %cid, %expected, %actual, "❌ Unexpected {protocol} request source");
                }
            }

            match resource_dst {
                Destination::IpAddr(resource_dst) => {
                    assert_destination_is_cidr_resource(gateway_received_request, resource_dst)
                }
                Destination::DomainName { name, .. } => {
                    let Some(query_timestamps) = sim_gateway.dns_query_timestamps.get(name) else {
                        tracing::error!(target: "assertions", %cid, %name, "Should have resolved domain at least once");
                        continue;
                    };

                    // To correctly assert whether the packet was routed to the correct IP, we need to find the timestamp of the DNS query closest to the packet timestamp.
                    // In other words: Packets should always use the IPs that were most recently resolved when they were sent.
                    let Some(dns_record_snapshot) = query_timestamps
                        .iter()
                        .filter(|query_timestamp| *query_timestamp <= request_received_at)
                        .max()
                    else {
                        tracing::error!(target: "assertions", %cid, %name, "Should have a relevant query timestamp");
                        continue;
                    };

                    // Split the proxy IP mapping by client and DNS record snapshot.
                    //
                    // Each client assigns its own proxy IPs, and when we re-resolve DNS, the mapping is allowed to change.
                    let mapping = proxy_ip_mappings
                        .entry((*cid, *dns_record_snapshot))
                        .or_default();

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

        for (payload, (_, request)) in received_requests {
            if !expected_handshakes.is_some_and(|e| e.contains_key(payload)) {
                tracing::error!(target: "assertions", %gateway, %payload, ?request, "❌ Received unexpected {protocol} request on gateway");
            }
        }

        let num_actual_handshakes = received_requests.len();

        if num_expected_handshakes != num_actual_handshakes {
            tracing::error!(target: "assertions", %num_expected_handshakes, %num_actual_handshakes, %gateway, "❌ Unexpected {protocol} requests");
        } else {
            tracing::info!(target: "assertions", %num_expected_handshakes, %gateway, "✅ Performed the expected {protocol} handshakes");
        }
    }
}

/// Asserts the handshakes between clients, i.e. traffic within a device pool.
fn assert_client_handshakes<P: EchoProtocol>(
    expected_handshakes_by_client: &BTreeMap<
        ClientId,
        BTreeMap<u64, (ClientId, Destination, P::FlowId)>,
    >,
    ref_clients: &BTreeMap<ClientId, &RefClient>,
    sim_clients: &BTreeMap<ClientId, &SimClient>,
    sent_requests: &BTreeMap<(ClientId, P::FlowId), (Instant, IpPacket)>,
    received_replies: &BTreeMap<(ClientId, P::FlowId), IpPacket>,
) {
    let protocol = P::NAME;

    for client in expected_handshakes_by_client.keys() {
        if !ref_clients.contains_key(client) {
            tracing::error!(target: "assertions", %client, "❌ Unknown Client");
        }
    }

    for (dst_client_id, sim_client) in sim_clients {
        let expected_handshakes = expected_handshakes_by_client.get(dst_client_id);
        let received_requests = P::received_requests_on_client(sim_client);

        let mut num_expected_handshakes = expected_handshakes.map_or(0, |e| e.len());

        for (payload, (src_client_id, _, flow)) in expected_handshakes.into_iter().flatten() {
            let _guard = P::span(*flow).entered();

            let src_ref_client = ref_clients.get(src_client_id).unwrap();
            let dst_ref_client = ref_clients.get(dst_client_id).unwrap();

            let Some((sent_at, client_sent_request)) = sent_requests.get(&(*src_client_id, *flow))
            else {
                tracing::error!(target: "assertions", %src_client_id, "❌ Missing {protocol} request on client");
                continue;
            };
            let Some(client_received_reply) =
                received_replies.get(&(*src_client_id, flow.reply_to()))
            else {
                // If the request was made after we reset our connections, missing a reply is okay.
                if dst_ref_client.has_reset_connections_within_ice_timeout(*sent_at) {
                    tracing::debug!(target: "assertions", %dst_client_id, "Destination client reset its connections and packet got lost");
                    num_expected_handshakes -= 1;
                    continue;
                }

                // A client→client connection idle long enough for its WireGuard session
                // to enter the re-key dead window drops this one packet without a reply
                // (see `MIN_IDLE_FOR_REKEY_DROP`), exactly like the client→gateway case above.
                //
                // TODO: Delete once ICEless is the default.
                if can_drop_during_rekey(
                    src_ref_client,
                    RejectionRemote::Client(*dst_client_id),
                    *sent_at,
                ) {
                    tracing::debug!(target: "assertions", %dst_client_id, "Tolerating {protocol} packet dropped in the WireGuard re-key window");
                    num_expected_handshakes -= 1;
                    continue;
                }

                tracing::error!(target: "assertions", %src_client_id, "❌ Missing {protocol} reply on client");
                continue;
            };
            assert_correct_src_and_dst_ips(client_sent_request, client_received_reply);
            assert_reply_echoes_payload::<P>(client_sent_request, client_received_reply);

            let Some((_, client_received_request)) = received_requests.get(payload) else {
                tracing::error!(target: "assertions", %src_client_id, "❌ Missing {protocol} request on destination client");
                continue;
            };

            {
                let expected = src_ref_client.tunnel_ip_for(client_received_request.source());
                let actual = client_received_request.source();

                if expected != actual {
                    tracing::error!(target: "assertions", %src_client_id, %expected, %actual, "❌ Unexpected {protocol} request source");
                }
            }

            {
                let actual = client_received_request.destination();
                let expected = dst_ref_client.tunnel_ip_for(actual);

                if expected != actual {
                    tracing::error!(target: "assertions", %dst_client_id, %expected, %actual, "❌ Unexpected {protocol} request destination");
                }
            }
        }

        for (payload, (_, request)) in received_requests {
            if !expected_handshakes.is_some_and(|e| e.contains_key(payload)) {
                tracing::error!(target: "assertions", %dst_client_id, %payload, ?request, "❌ Received unexpected {protocol} request on client");
            }
        }

        let num_actual_handshakes = received_requests.len();

        if num_expected_handshakes != num_actual_handshakes {
            tracing::error!(target: "assertions", %num_expected_handshakes, %num_actual_handshakes, %dst_client_id, "❌ Unexpected {protocol} requests");
        } else {
            tracing::info!(target: "assertions", %num_expected_handshakes, %dst_client_id, "✅ Performed the expected {protocol} handshakes");
        }
    }
}

fn can_drop_during_rekey(
    ref_client: &RefClient,
    remote: RejectionRemote,
    sent_at: Instant,
) -> bool {
    match remote {
        RejectionRemote::Local => false,
        RejectionRemote::Gateway(gateway) => ref_client
            .last_packet_sent_to_gateway_before(gateway, sent_at)
            .is_none_or(|previous| sent_at.duration_since(previous) >= MIN_IDLE_FOR_REKEY_DROP),
        RejectionRemote::Client(client) => ref_client
            .last_packet_sent_to_client_before(client, sent_at)
            .is_some_and(|previous| sent_at.duration_since(previous) >= MIN_IDLE_FOR_REKEY_DROP),
    }
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
    let unexpected_dns_replies = sim_client
        .received_udp_dns_responses
        .keys()
        .filter(|response| !ref_client.expected_udp_dns_handshakes.contains(response))
        .collect::<Vec<_>>();

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
    let unexpected_dns_responses = sim_client
        .received_tcp_dns_responses
        .iter()
        .filter(|response| !ref_client.expected_tcp_dns_handshakes.contains(response))
        .collect::<Vec<_>>();

    if !unexpected_dns_responses.is_empty() {
        tracing::error!(target: "assertions", ?unexpected_dns_responses, "❌ Unexpected TCP DNS responses on client");
    }

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

/// Asserts that a successful reply echoes back the request's payload.
///
/// The simulated gateways and clients only ever echo requests back, so any
/// difference in payload means packets got corrupted or mixed up in transit.
///
/// ICMP errors quote the failed request instead of echoing its payload; they are
/// validated separately and skipped here.
fn assert_reply_echoes_payload<P: EchoProtocol>(
    client_sent_request: &IpPacket,
    client_received_reply: &IpPacket,
) {
    if client_received_reply
        .icmp_error()
        .is_ok_and(|error| error.is_some())
    {
        return;
    }

    let expected = P::payload(client_sent_request);
    let actual = P::payload(client_received_reply);

    if actual != expected {
        tracing::error!(target: "assertions", ?actual, ?expected, "❌ Reply does not echo the request payload");
    } else {
        tracing::info!(target: "assertions", "✅ Reply echoes the request payload");
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

fn assert_destination_is_cidr_resource(gateway_received_request: &IpPacket, expected: &IpAddr) {
    let actual = gateway_received_request.destination();

    if actual != *expected {
        tracing::error!(target: "assertions", %actual, %expected, "❌ Incorrect resource destination");
    } else {
        tracing::info!(target: "assertions", ip = %actual, "✅ Request targets correct resource");
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
