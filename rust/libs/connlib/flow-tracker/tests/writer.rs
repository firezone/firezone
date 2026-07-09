//! Integration tests of the tracker with `flow-log-writer`: the tracker's
//! records, emitted as tracing events, must spool losslessly into reports.

#![allow(clippy::unwrap_used)]

use std::{
    net::{Ipv4Addr, SocketAddr},
    path::Path,
    time::{Duration, Instant},
};

use base64::Engine as _;
use chrono::TimeZone as _;
use connlib_model::{ClientId, ClientOrGatewayId, ResourceId};
use flow_tracker::{FlowClose, FlowProtocol, IngestToken, Record, Role, Tracker};
use ip_packet::IpPacket;
use tracing_subscriber::layer::SubscriberExt as _;

/// Guards the field contract between [`flow_tracker::emit`] and the writer's
/// layer: an emitted record must round-trip losslessly into a spooled report.
#[test]
fn emitted_records_spool_via_flow_log_writer_layer() {
    let authz_id = "11111111-1111-1111-1111-111111111111";
    let record = Record {
        ingest_token: test_token(authz_id, "responder"),
        protocol: FlowProtocol::Tcp,
        inner_src_ip: "100.64.0.1".parse().unwrap(),
        inner_src_port: 1234,
        inner_dst_ip: "10.0.0.5".parse().unwrap(),
        inner_dst_port: 443,
        domain: Some("download.httpbin".parse().unwrap()),
        outer_src_ip: "198.51.100.1".parse().unwrap(),
        outer_src_port: 51820,
        outer_dst_ip: "203.0.113.7".parse().unwrap(),
        outer_dst_port: 51820,
        flow_start: chrono::Utc.timestamp_opt(1_700_000_000, 500).unwrap(),
        close: Some(FlowClose {
            flow_end: chrono::Utc.timestamp_opt(1_700_000_060, 0).unwrap(),
            last_packet: chrono::Utc.timestamp_opt(1_700_000_059, 0).unwrap(),
            rx_packets: 10,
            tx_packets: 12,
            rx_bytes: 1024,
            tx_bytes: 2048,
        }),
    };

    let dir = tempfile::tempdir().unwrap();
    flow_log_writer::write_token(dir.path(), record.ingest_token.as_str()).unwrap();

    let (layer, guard) = flow_log_writer::layer(dir.path().to_owned());
    let subscriber = tracing_subscriber::registry().with(layer);
    tracing::subscriber::with_default(subscriber, || flow_tracker::emit(&record));
    drop(guard); // joins the writer thread, so the report is on disk

    let authz_dir = dir.path().join("responder").join(authz_id);
    let payload = read_report(&authz_dir, ".end.json");

    assert_eq!(payload["protocol"], "tcp");
    assert_eq!(payload["inner_src_ip"], record.inner_src_ip.to_string());
    assert_eq!(payload["inner_src_port"], record.inner_src_port);
    assert_eq!(payload["inner_dst_ip"], record.inner_dst_ip.to_string());
    assert_eq!(payload["inner_dst_port"], record.inner_dst_port);
    assert_eq!(payload["domain"], "download.httpbin");
    assert_eq!(payload["outer_src_ip"], record.outer_src_ip.to_string());
    assert_eq!(payload["outer_src_port"], record.outer_src_port);
    assert_eq!(payload["outer_dst_ip"], record.outer_dst_ip.to_string());
    assert_eq!(payload["outer_dst_port"], record.outer_dst_port);
    assert_eq!(payload["flow_start"], format!("{:?}", record.flow_start));
    // Attribution rides the token, not the spooled record.
    assert!(payload.get("actor_id").is_none());

    let close = record.close.as_ref().unwrap();
    assert_eq!(payload["flow_end"], format!("{:?}", close.flow_end));
    assert_eq!(payload["last_packet"], format!("{:?}", close.last_packet));
    assert_eq!(payload["rx_packets"], close.rx_packets);
    assert_eq!(payload["tx_packets"], close.tx_packets);
    assert_eq!(payload["rx_bytes"], close.rx_bytes);
    assert_eq!(payload["tx_bytes"], close.tx_bytes);
}

/// Drives the tracker as a Gateway would and asserts that both halves of the
/// flow's report end up in the spool.
#[test]
fn tracked_packets_spool_open_and_completed_reports() {
    let authz_id = "22222222-2222-2222-2222-222222222222";
    let token = test_token(authz_id, "responder");

    let dir = tempfile::tempdir().unwrap();
    flow_log_writer::write_token(dir.path(), token.as_str()).unwrap();

    let (layer, guard) = flow_log_writer::layer(dir.path().to_owned());
    let subscriber = tracing_subscriber::registry().with(layer);

    let now = Instant::now();
    let mut tracker =
        Tracker::<(ClientId, ResourceId)>::new(now, Duration::from_secs(1_700_000_000));
    tracker.set_enabled(true);

    let client = ClientId::from_u128(1);
    let resource = ResourceId::from_u128(2);

    // The Gateway's socket and the Client's public endpoint.
    let local = "203.0.113.1:51820".parse::<SocketAddr>().unwrap();
    let remote = "198.51.100.1:45000".parse::<SocketAddr>().unwrap();

    let client_ip = "100.64.0.1".parse::<Ipv4Addr>().unwrap();
    let resource_ip = "10.0.0.5".parse::<Ipv4Addr>().unwrap();
    let request =
        ip_packet::make::udp_packet(client_ip, resource_ip, 1234, 5201, b"hello").unwrap();
    let reply = ip_packet::make::udp_packet(resource_ip, client_ip, 5201, 1234, b"world!").unwrap();

    tracing::subscriber::with_default(subscriber, || {
        {
            let flow = tracker.begin_network_packet(local, remote, now);
            flow_tracker::record_decrypted_packet(&request);
            flow_tracker::record_peer(client, Role::Responder);
            flow_tracker::record_resource(resource);
            flow_tracker::record_ingest_token(Some(token.clone()));
            drop(flow);
        }

        {
            let flow = tracker.begin_tun_packet(&reply, now);
            flow_tracker::record_peer(client, Role::Responder);
            flow_tracker::record_resource(resource);
            flow_tracker::record_transmit(Some(local), remote);
            drop(flow);
        }

        tracker.close_all(now);
    });
    drop(guard); // joins the writer thread, so the reports are on disk

    let authz_dir = dir.path().join("responder").join(authz_id);

    let open = read_report(&authz_dir, ".start.json");
    assert_eq!(open["protocol"], "udp");
    assert_eq!(open["inner_src_ip"], "100.64.0.1");
    assert_eq!(open["inner_src_port"], 1234);
    assert_eq!(open["inner_dst_ip"], "10.0.0.5");
    assert_eq!(open["inner_dst_port"], 5201);
    assert_eq!(open["outer_src_ip"], "198.51.100.1");
    assert_eq!(open["outer_src_port"], 45000);
    assert_eq!(open["outer_dst_ip"], "203.0.113.1");
    assert_eq!(open["outer_dst_port"], 51820);
    assert!(open.get("flow_end").is_none());

    let completed = read_report(&authz_dir, ".end.json");
    assert_eq!(completed["inner_src_ip"], "100.64.0.1");
    assert_eq!(completed["tx_packets"], 1);
    assert_eq!(completed["tx_bytes"], 5);
    assert_eq!(completed["rx_packets"], 1);
    assert_eq!(completed["rx_bytes"], 6);
}

#[test]
fn syn_retransmit_updates_flow_instead_of_splitting() {
    let authz_id = "33333333-3333-3333-3333-333333333333";
    let spool = SpoolObserver::new(authz_id);
    let mut tracker = enabled_tracker();
    let t0 = Instant::now();

    spool.observe(|| {
        drive_tx(&mut tracker, &tcp_packet(syn(), &[]), authz_id, t0);
        drive_tx(
            &mut tracker,
            &tcp_packet(syn(), &[]),
            authz_id,
            t0 + Duration::from_secs(1),
        );
        tracker.close_all(t0 + Duration::from_secs(2));
    });

    let flows = spool.completed_flows();
    assert_eq!(
        packet_counts(&flows),
        vec![(2, 0)],
        "retransmitted SYN counts into the same flow"
    );
}

#[test]
fn syn_after_return_traffic_splits_flow() {
    let authz_id = "44444444-4444-4444-4444-444444444444";
    let spool = SpoolObserver::new(authz_id);
    let mut tracker = enabled_tracker();
    let t0 = Instant::now();

    spool.observe(|| {
        drive_tx(&mut tracker, &tcp_packet(syn(), &[]), authz_id, t0);
        drive_rx(
            &mut tracker,
            &tcp_return_packet(&[0; 100]),
            t0 + Duration::from_secs(1),
        );
        drive_tx(
            &mut tracker,
            &tcp_packet(syn(), &[]),
            authz_id,
            t0 + Duration::from_secs(2),
        );
        tracker.close_all(t0 + Duration::from_secs(3));
    });

    let flows = spool.completed_flows();
    assert_eq!(
        packet_counts(&flows),
        vec![(1, 0), (1, 1)],
        "a new SYN closes the old flow and starts a fresh one"
    );
}

#[test]
fn bare_ack_does_not_create_flow() {
    let authz_id = "55555555-5555-5555-5555-555555555555";
    let spool = SpoolObserver::new(authz_id);
    let mut tracker = enabled_tracker();
    let t0 = Instant::now();

    spool.observe(|| {
        drive_tx(&mut tracker, &tcp_packet(ack(), &[]), authz_id, t0);
        tracker.close_all(t0 + Duration::from_secs(1));
    });

    assert_eq!(packet_counts(&spool.completed_flows()), vec![]);
}

#[test]
fn data_packet_creates_flow_without_syn() {
    let authz_id = "66666666-6666-6666-6666-666666666666";
    let spool = SpoolObserver::new(authz_id);
    let mut tracker = enabled_tracker();
    let t0 = Instant::now();

    spool.observe(|| {
        drive_tx(&mut tracker, &tcp_packet(ack(), &[0; 100]), authz_id, t0);
        tracker.close_all(t0 + Duration::from_secs(1));
    });

    assert_eq!(packet_counts(&spool.completed_flows()), vec![(1, 0)]);
}

fn enabled_tracker() -> Tracker<ClientOrGatewayId> {
    let mut tracker = Tracker::new(Instant::now(), Duration::from_secs(1_700_000_000));
    tracker.set_enabled(true);

    tracker
}

/// Runs the initiator-to-responder packet through the tracker's public
/// entry points, as the gateway does for a packet arriving over the network.
fn drive_tx(
    tracker: &mut Tracker<ClientOrGatewayId>,
    packet: &IpPacket,
    authz_id: &str,
    now: Instant,
) {
    let _flow = tracker.begin_network_packet(
        "198.51.100.1:51820".parse().unwrap(),
        "203.0.113.7:51820".parse().unwrap(),
        now,
    );
    flow_tracker::record_decrypted_packet(packet);
    flow_tracker::record_peer(ClientId::from_u128(1), Role::Responder);
    flow_tracker::record_ingest_token(Some(test_token(authz_id, "responder")));
}

/// Runs the responder-to-initiator return packet through the tracker's
/// public entry points, as the gateway does for a packet read from TUN.
fn drive_rx(tracker: &mut Tracker<ClientOrGatewayId>, packet: &IpPacket, now: Instant) {
    let _flow = tracker.begin_tun_packet(packet, now);
    flow_tracker::record_peer(ClientId::from_u128(1), Role::Responder);
    flow_tracker::record_transmit(
        Some("198.51.100.1:51820".parse().unwrap()),
        "203.0.113.7:51820".parse().unwrap(),
    );
}

fn syn() -> ip_packet::make::TcpFlags {
    ip_packet::make::TcpFlags {
        syn: true,
        ..Default::default()
    }
}

fn ack() -> ip_packet::make::TcpFlags {
    ip_packet::make::TcpFlags {
        ack: true,
        ..Default::default()
    }
}

fn tcp_packet(flags: ip_packet::make::TcpFlags, payload: &[u8]) -> IpPacket {
    ip_packet::make::tcp_packet(
        "100.64.0.1".parse::<Ipv4Addr>().unwrap(),
        "10.0.0.5".parse::<Ipv4Addr>().unwrap(),
        1234,
        443,
        flags,
        payload,
    )
    .unwrap()
}

/// The matching return packet for [`tcp_packet`], in its natural
/// (responder-to-initiator) orientation.
fn tcp_return_packet(payload: &[u8]) -> IpPacket {
    ip_packet::make::tcp_packet(
        "10.0.0.5".parse::<Ipv4Addr>().unwrap(),
        "100.64.0.1".parse::<Ipv4Addr>().unwrap(),
        443,
        1234,
        ip_packet::make::TcpFlags::default(),
        payload,
    )
    .unwrap()
}

/// Observes the tracker's only public output: the records it emits, spooled
/// to disk by `flow-log-writer`'s layer.
struct SpoolObserver {
    dir: tempfile::TempDir,
    authz_id: String,
}

impl SpoolObserver {
    fn new(authz_id: &str) -> Self {
        let dir = tempfile::tempdir().unwrap();
        flow_log_writer::write_token(dir.path(), test_token(authz_id, "responder").as_str())
            .unwrap();

        Self {
            dir,
            authz_id: authz_id.to_owned(),
        }
    }

    fn observe(&self, f: impl FnOnce()) {
        let (layer, guard) = flow_log_writer::layer(self.dir.path().to_owned());
        let subscriber = tracing_subscriber::registry().with(layer);

        tracing::subscriber::with_default(subscriber, f);
        drop(guard); // joins the writer thread, so the reports are on disk
    }

    fn completed_flows(&self) -> Vec<serde_json::Value> {
        let authz_dir = self.dir.path().join("responder").join(&self.authz_id);

        std::fs::read_dir(&authz_dir)
            .expect("spooled report dir exists")
            .map(|entry| entry.unwrap().path())
            .filter(|path| path.to_string_lossy().ends_with(".end.json"))
            .map(|path| flow_log_spool::deserialize(&std::fs::read(path).unwrap()).unwrap())
            .collect()
    }
}

/// The `(tx_packets, rx_packets)` of each completed flow, in stable order.
fn packet_counts(flows: &[serde_json::Value]) -> Vec<(u64, u64)> {
    let mut counts = flows
        .iter()
        .map(|flow| {
            (
                flow["tx_packets"].as_u64().unwrap(),
                flow["rx_packets"].as_u64().unwrap(),
            )
        })
        .collect::<Vec<_>>();
    counts.sort_unstable();

    counts
}

/// A JWT payload carrying every claim the portal guarantees on a token.
fn required_claims(policy_authorization_id: &str, role: &str) -> String {
    format!(
        r#"{{"account_id":"c1e296cd-b8ff-4565-8a4c-b6023a4a4b10","iat":1782756000,"exp":1785434400,"uploads_enabled":true,"role":"{role}","device_id":"d-1","policy_authorization_id":"{policy_authorization_id}","policy_id":"p-1","resource_id":"r-1","resource_name":"web","actor_id":"a-1","actor_name":"Alice","authorized_at":"2026-07-01T00:00:00Z","authorization_expires_at":"2026-07-02T00:00:00Z"}}"#
    )
}

/// Assembles and parses a well-formed ingest token for `authz_id`.
fn test_token(authz_id: &str, role: &str) -> IngestToken {
    let encode = |bytes: &[u8]| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes);

    let header = encode(br#"{"alg":"HS256"}"#);
    let payload = encode(required_claims(authz_id, role).as_bytes());
    let token = format!("{header}.{payload}.{}", encode(b"signature"));

    serde_json::from_value(serde_json::Value::String(token)).unwrap()
}

/// Reads the payload of the only report in `authz_dir` whose name ends in `suffix`.
fn read_report(authz_dir: &Path, suffix: &str) -> serde_json::Value {
    let report = std::fs::read_dir(authz_dir)
        .expect("spooled report dir exists")
        .map(|entry| entry.unwrap().path())
        .find(|path| path.to_string_lossy().ends_with(suffix))
        .expect("report exists");

    flow_log_spool::deserialize(&std::fs::read(report).unwrap()).unwrap()
}
