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
use connlib_model::{ClientId, ResourceId};
use flow_tracker::{FlowClose, FlowProtocol, IngestToken, Record, Role, Tracker};
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
