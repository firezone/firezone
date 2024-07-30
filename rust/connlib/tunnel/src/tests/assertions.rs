use super::{
    sim_client::{RefClient, SimClient},
    sim_gateway::SimGateway,
};
use crate::tests::reference::ResourceDst;
use connlib_shared::{messages::GatewayId, DomainName};
use ip_packet::IpPacket;
use std::{
    collections::{hash_map::Entry, BTreeMap, HashMap, HashSet, VecDeque},
    marker::PhantomData,
    net::IpAddr,
    sync::atomic::{AtomicBool, Ordering},
};
use tracing::{Level, Subscriber};
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
    sim_gateways: HashMap<GatewayId, &SimGateway>,
    global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
) {
    let unexpected_icmp_replies = find_unexpected_entries(
        &ref_client
            .expected_icmp_handshakes
            .values()
            .flatten()
            .collect(),
        &sim_client.received_icmp_replies,
        |(_, seq_a, id_a), (seq_b, id_b)| seq_a == seq_b && id_a == id_b,
    );

    if !unexpected_icmp_replies.is_empty() {
        tracing::error!(target: "assertions", ?unexpected_icmp_replies, "❌ Unexpected ICMP replies on client");
    }

    for (gid, expected_icmp_handshakes) in ref_client.expected_icmp_handshakes.iter() {
        let gateway = sim_gateways.get(gid).unwrap();

        let num_expected_handshakes = expected_icmp_handshakes.len();
        let num_actual_handshakes = gateway.received_icmp_requests.len();

        if num_expected_handshakes != num_actual_handshakes {
            tracing::error!(target: "assertions", %num_expected_handshakes, %num_actual_handshakes, %gid, "❌ Unexpected ICMP requests");
        } else {
            tracing::info!(target: "assertions", %num_expected_handshakes, %gid, "✅ Performed the expected ICMP handshakes");
        }
    }

    let mut mapping = HashMap::new();

    // Assert properties of the individual ICMP handshakes per gateway.
    // Due to connlib's implementation of NAT64, we cannot match the packets sent by the client to the packets arriving at the resource by port or ICMP identifier.
    // Thus, we rely on the _order_ here which is why the packets are indexed by gateway in the `RefClient`.
    for (gateway, expected_icmp_handshakes) in &ref_client.expected_icmp_handshakes {
        let received_icmp_requests = &sim_gateways.get(gateway).unwrap().received_icmp_requests;

        for ((resource_dst, seq, identifier), gateway_received_request) in
            expected_icmp_handshakes.iter().zip(received_icmp_requests)
        {
            let _guard =
                tracing::info_span!(target: "assertions", "icmp", %seq, %identifier).entered();

            let Some(client_sent_request) = sim_client.sent_icmp_requests.get(&(*seq, *identifier))
            else {
                tracing::error!(target: "assertions", "❌ Missing ICMP request on client");
                continue;
            };
            let Some(client_received_reply) =
                sim_client.received_icmp_replies.get(&(*seq, *identifier))
            else {
                tracing::error!(target: "assertions", "❌ Missing ICMP reply on client");
                continue;
            };

            assert_correct_src_and_dst_ips(client_sent_request, client_received_reply);

            {
                let expected = ref_client.tunnel_ip_for(gateway_received_request.source());
                let actual = gateway_received_request.source();

                if expected != actual {
                    tracing::error!(target: "assertions", %expected, %actual, "❌ Unexpected request source");
                }
            }

            match resource_dst {
                ResourceDst::Cidr(resource_dst) => {
                    assert_destination_is_cdir_resource(gateway_received_request, resource_dst)
                }
                ResourceDst::Dns(domain) => {
                    assert_destination_is_dns_resource(
                        gateway_received_request,
                        global_dns_records,
                        domain,
                    );

                    assert_proxy_ip_mapping_is_stable(
                        client_sent_request,
                        gateway_received_request,
                        &mut mapping,
                    )
                }
                ResourceDst::Internet(resource_dst) => {
                    assert_destination_is_cdir_resource(gateway_received_request, resource_dst)
                }
            }
        }
    }
}

pub(crate) fn assert_known_hosts_are_valid(ref_client: &RefClient, sim_client: &SimClient) {
    for (record, actual) in &sim_client.dns_records {
        if let Some(expected) = ref_client.known_hosts.get(&record.to_string()) {
            if actual != expected {
                tracing::error!(target: "assertions", ?actual, ?expected, "❌ Unexpected known-hosts");
            }
        }
    }
}

pub(crate) fn assert_dns_packets_properties(ref_client: &RefClient, sim_client: &SimClient) {
    let unexpected_dns_replies = find_unexpected_entries(
        &ref_client.expected_dns_handshakes,
        &sim_client.received_dns_responses,
        |id_a, id_b| id_a == id_b,
    );

    if !unexpected_dns_replies.is_empty() {
        tracing::error!(target: "assertions", ?unexpected_dns_replies, "❌ Unexpected DNS replies on client");
    }

    for query_id in ref_client.expected_dns_handshakes.iter() {
        let _guard = tracing::info_span!(target: "assertions", "dns", %query_id).entered();

        let Some(client_sent_query) = sim_client.sent_dns_queries.get(query_id) else {
            tracing::error!(target: "assertions", ?unexpected_dns_replies, "❌ Missing DNS query on client");
            continue;
        };
        let Some(client_received_response) = sim_client.received_dns_responses.get(query_id) else {
            tracing::error!(target: "assertions", ?unexpected_dns_replies, "❌ Missing DNS response on client");
            continue;
        };

        assert_correct_src_and_dst_ips(client_sent_query, client_received_response);
        assert_correct_src_and_dst_udp_ports(client_sent_query, client_received_response);
    }
}

fn assert_correct_src_and_dst_ips(
    client_sent_request: &IpPacket<'_>,
    client_received_reply: &IpPacket<'_>,
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
    client_sent_request: &IpPacket<'_>,
    client_received_reply: &IpPacket<'_>,
) {
    let client_sent_request = client_sent_request.unwrap_as_udp();
    let client_received_reply = client_received_reply.unwrap_as_udp();

    let req_dst = client_sent_request.get_destination();
    let res_src = client_received_reply.get_source();

    if req_dst != res_src {
        tracing::error!(target: "assertions", %req_dst, %res_src, "❌ req dst port != res src port");
    } else {
        tracing::info!(target: "assertions", port = %req_dst, "✅ req dst port == res src port");
    }

    let req_src = client_sent_request.get_source();
    let res_dst = client_received_reply.get_destination();

    if req_src != res_dst {
        tracing::error!(target: "assertions", %req_src, %res_dst, "❌ req src port != res dst port");
    } else {
        tracing::info!(target: "assertions", port = %req_src, "✅ req src port == res dst port");
    }
}

fn assert_destination_is_cdir_resource(gateway_received_request: &IpPacket<'_>, expected: &IpAddr) {
    let actual = gateway_received_request.destination();

    if actual != *expected {
        tracing::error!(target: "assertions", %actual, %expected, "❌ Unknown resource IP");
    } else {
        tracing::info!(target: "assertions", ip = %actual, "✅ ICMP request targets correct resource");
    }
}

fn assert_destination_is_dns_resource(
    gateway_received_request: &IpPacket<'_>,
    global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
    domain: &DomainName,
) {
    let actual = gateway_received_request.destination();
    let Some(possible_resource_ips) = global_dns_records.get(domain) else {
        tracing::error!(target: "assertions", %domain, "❌ No DNS records");
        return;
    };

    if !possible_resource_ips.contains(&actual) {
        tracing::error!(target: "assertions", %actual, ?possible_resource_ips, "❌ Unknown resource IP");
    } else {
        tracing::info!(target: "assertions", ip = %actual, "✅ Resource IP is valid");
    }
}

/// Assert that the mapping of proxy IP to resource destination is stable.
///
/// How connlib assigns proxy IPs for domains is an implementation detail.
/// Yet, we care that it remains stable to ensure that any form of sticky sessions don't get broken (i.e. packets to one IP are always routed to the same IP on the gateway).
/// To assert this, we build up a map as we iterate through all packets that have been sent.
fn assert_proxy_ip_mapping_is_stable(
    client_sent_request: &IpPacket<'_>,
    gateway_received_request: &IpPacket<'_>,
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
    actual: &'a HashMap<K, V>,
    is_equal: impl Fn(&E, &K) -> bool,
) -> Vec<&'a V> {
    actual
        .iter()
        .filter(|(k, _)| !expected.iter().any(|e| is_equal(e, k)))
        .map(|(_, v)| v)
        .collect()
}

/// Tracks whether any [`Level::ERROR`] events are emitted and panics on `Drop` in case.
pub(crate) struct PanicOnErrorEvents<S> {
    subscriber: PhantomData<S>,
    has_seen_error: AtomicBool,
}

impl<S> Default for PanicOnErrorEvents<S> {
    fn default() -> Self {
        Self {
            subscriber: Default::default(),
            has_seen_error: Default::default(),
        }
    }
}

impl<S> Drop for PanicOnErrorEvents<S> {
    fn drop(&mut self) {
        if self.has_seen_error.load(Ordering::SeqCst) {
            panic!("At least one assertion failed");
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
