use opentelemetry::{KeyValue, Value};
use opentelemetry_sdk::{
    Resource,
    resource::{EnvResourceDetector, ResourceDetector, TelemetryResourceDetector},
};

pub mod attr {
    use ip_packet::{IpPacket, IpVersion};
    use opentelemetry::Value;
    use std::{io, net::SocketAddr};

    use super::*;

    #[macro_export]
    macro_rules! service_name {
        () => {
            ::opentelemetry::KeyValue::new("service.name", env!("CARGO_PKG_NAME"))
        };
    }

    #[macro_export]
    macro_rules! service_version {
        () => {
            ::opentelemetry::KeyValue::new("service.version", env!("CARGO_PKG_VERSION"))
        };
    }

    pub use service_name;
    pub use service_version;

    pub fn service_instance_id(maybe_legacy_id: String) -> KeyValue {
        KeyValue::new(
            "service.instance.id",
            crate::maybe_hash_device_id(maybe_legacy_id),
        )
    }

    pub fn network_transport_udp() -> KeyValue {
        KeyValue::new("network.transport", "udp")
    }

    pub fn network_type_for_packet(p: &IpPacket) -> KeyValue {
        match p.version() {
            IpVersion::V4 => network_type_ipv4(),
            IpVersion::V6 => network_type_ipv6(),
        }
    }

    pub fn network_type_for_addr(addr: SocketAddr) -> KeyValue {
        match addr {
            SocketAddr::V4(_) => network_type_ipv4(),
            SocketAddr::V6(_) => network_type_ipv6(),
        }
    }

    pub fn network_type_ipv4() -> KeyValue {
        KeyValue::new("network.type", "ipv4")
    }

    pub fn network_type_ipv6() -> KeyValue {
        KeyValue::new("network.type", "ipv6")
    }

    pub fn network_io_direction_receive() -> KeyValue {
        KeyValue::new("network.io.direction", "receive")
    }

    pub fn network_io_direction_transmit() -> KeyValue {
        KeyValue::new("network.io.direction", "transmit")
    }

    /// The kind of socket a connection's path uses, e.g. `PeerToPeer` or `RelayToRelay`.
    pub fn connection_socket(socket: &'static str) -> KeyValue {
        KeyValue::new("connection.socket", socket)
    }

    pub fn io_error_code(e: &io::Error) -> KeyValue {
        KeyValue::new("error.code", e.raw_os_error().unwrap_or_default() as i64)
    }

    pub fn io_error_type(e: &io::Error) -> KeyValue {
        error_type(format!("io::ErrorKind::{:?}", e.kind()))
    }

    pub fn error_type(value: impl Into<Value>) -> KeyValue {
        KeyValue::new("error.type", value)
    }

    pub fn queue_item_ip_packet() -> KeyValue {
        KeyValue::new("queue.item", "ip-packet")
    }

    pub fn queue_item_gro_batch() -> KeyValue {
        KeyValue::new("queue.item", "udp-gro-batch")
    }

    pub fn queue_item_gso_batch() -> KeyValue {
        KeyValue::new("queue.item", "udp-gso-batch")
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn io_error_type_serialisation() {
            let error = io::Error::from(io::ErrorKind::NetworkUnreachable);

            assert_eq!(
                io_error_type(&error),
                KeyValue::new("error.type", "io::ErrorKind::NetworkUnreachable")
            );
        }
    }
}

/// Caps how many layers of an error's source chain are recorded as attributes.
const MAX_ERROR_LAYERS: usize = 5;

/// Pre-computed attribute keys, one per recorded error-chain layer.
const ERROR_TYPE_KEYS: [&str; MAX_ERROR_LAYERS] = [
    "error.type.0",
    "error.type.1",
    "error.type.2",
    "error.type.3",
    "error.type.4",
];

/// Encodes an error's source chain into per-layer `error.type.{N}` attributes.
///
/// Each layer is the error's `Display` string with variable substrings (IP addresses,
/// UUIDs) replaced by static placeholders to keep metric cardinality low.
pub fn error_layers(error: &anyhow::Error) -> Vec<KeyValue> {
    error
        .chain()
        .map(error_type)
        .zip(ERROR_TYPE_KEYS)
        .map(|(error, key)| KeyValue::new(key, error))
        .collect()
}

fn error_type(error: &(dyn std::error::Error + 'static)) -> Value {
    // The kind is stable, whereas the Display of `io::Error` includes an OS-specific message.
    if let Some(io) = error.downcast_ref::<std::io::Error>() {
        return attr::io_error_type(io).value;
    }

    Value::from(normalize(&format!("{error}")))
}

/// Replaces variable tokens in an error message with static placeholders.
///
/// Splits on whitespace and classifies each token via the stdlib network parsers
/// and the `uuid` crate.  Tokens that parse as a `SocketAddr` or `IpAddr` become
/// `{addr}`, UUIDs become `{uuid}`, and bare integers become `{num}`.  Leading and
/// trailing punctuation is preserved around a replaced token.
fn normalize(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;

    while !rest.is_empty() {
        // Preserve leading whitespace runs.
        let trimmed = rest.trim_start_matches(|c: char| c.is_ascii_whitespace());
        out.push_str(&rest[..rest.len() - trimmed.len()]);
        rest = trimmed;

        // Find the end of the next non-whitespace token.
        let token_end = rest
            .find(|c: char| c.is_ascii_whitespace())
            .unwrap_or(rest.len());
        let token = &rest[..token_end];
        rest = &rest[token_end..];

        if !token.is_empty() {
            out.push_str(&normalize_token(token));
        }
    }

    out
}

/// Attempts to replace a single whitespace-delimited token with a placeholder.
///
/// Leading characters that cannot start an address literal (anything except
/// alphanumerics, `[`, and `:`) are treated as punctuation and passed through
/// unchanged.  The same applies to trailing characters that cannot end one
/// (anything except alphanumerics and `]`).
fn normalize_token(token: &str) -> String {
    let stripped =
        token.trim_start_matches(|c: char| !c.is_ascii_alphanumeric() && c != '[' && c != ':');
    let prefix_len = token.len() - stripped.len();
    let prefix = &token[..prefix_len];

    let core = stripped.trim_end_matches(|c: char| !c.is_ascii_alphanumeric() && c != ']');
    let suffix = &stripped[core.len()..];

    match classify(core) {
        Some(placeholder) => format!("{prefix}{placeholder}{suffix}"),
        None => token.to_owned(),
    }
}

/// Returns the placeholder string for a token that carries variable data, or `None`.
fn classify(s: &str) -> Option<&'static str> {
    if s.parse::<std::net::SocketAddr>().is_ok() {
        return Some("{ip}:{port}");
    }

    if s.parse::<std::net::IpAddr>().is_ok() {
        return Some("{ip}");
    }

    if s.parse::<uuid::Uuid>().is_ok() {
        return Some("{uuid}");
    }

    if !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) {
        return Some("{num}");
    }

    // Require at least 8 chars to avoid matching common English words (e.g. "a", "be",
    // "cafe") that happen to be valid hex. Pure-digit strings are caught above as {num}.
    if s.len() >= 8 && s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Some("{hex}");
    }

    // Hex groups separated by dashes (e.g. non-standard IDs, truncated UUIDs).
    // Every group must be non-empty and all hex digits; at least two groups required.
    let parts: Vec<&str> = s.split('-').collect();
    if parts.len() >= 2
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_hexdigit()))
    {
        return Some("{hex}");
    }

    None
}

#[cfg(test)]
mod error_layer_tests {
    use super::*;

    #[test]
    fn io_error_uses_error_kind() {
        let error =
            anyhow::Error::new(std::io::Error::from(std::io::ErrorKind::NetworkUnreachable));

        assert_eq!(
            error_layers(&error)[0],
            KeyValue::new("error.type.0", "io::ErrorKind::NetworkUnreachable")
        );
    }

    #[test]
    fn struct_error_masks_variable_fields() {
        let error = anyhow::Error::new(StructError {
            client_ip: "1.2.3.4",
        });

        assert_eq!(
            error_layers(&error)[0],
            KeyValue::new("error.type.0", "failed to handle packet from {ip}")
        );
    }

    #[test]
    fn tuple_error_masks_variable_value() {
        let error = anyhow::Error::new(TupleError("1.2.3.4"));

        assert_eq!(
            error_layers(&error)[0],
            KeyValue::new("error.type.0", "{ip} is not a client IP")
        );
    }

    #[test]
    fn context_chain_is_recorded_per_layer() {
        let error = anyhow::Error::new(StructError {
            client_ip: "1.2.3.4",
        })
        .context(TupleError("Test"));

        let layers = error_layers(&error);

        assert_eq!(
            layers[0],
            KeyValue::new("error.type.0", "Test is not a client IP")
        );
        assert_eq!(
            layers[1],
            KeyValue::new("error.type.1", "failed to handle packet from {ip}")
        );
    }

    #[test]
    fn caps_recorded_layers() {
        let mut error = anyhow::Error::msg("root cause");
        for i in 0..(MAX_ERROR_LAYERS * 2) {
            error = error.context(format!("context {i}"));
        }

        assert_eq!(error_layers(&error).len(), MAX_ERROR_LAYERS);
    }

    #[derive(Debug, thiserror::Error)]
    #[error("failed to handle packet from {client_ip}")]
    struct StructError {
        client_ip: &'static str,
    }

    #[derive(Debug, thiserror::Error)]
    #[error("{0} is not a client IP")]
    struct TupleError(&'static str);
}

#[cfg(test)]
mod normalize_tests {
    use super::normalize;

    // --- IPv4 ---

    #[test]
    fn ipv4_bare() {
        assert_eq!(
            normalize("not a client ip: 1.2.3.4"),
            "not a client ip: {ip}"
        );
    }

    #[test]
    fn ipv4_with_port() {
        assert_eq!(
            normalize("failed to bind on 0.0.0.0:53"),
            "failed to bind on {ip}:{port}"
        );
        assert_eq!(
            normalize("src 1.2.3.4:8080 dst 5.6.7.8:9090"),
            "src {ip}:{port} dst {ip}:{port}"
        );
    }

    #[test]
    fn ipv4_not_matched_in_identifier() {
        // Digit immediately preceded by alphanumeric — do not mangle.
        assert_eq!(normalize("v1.2.3.4"), "v1.2.3.4");
    }

    // --- IPv6 ---

    #[test]
    fn ipv6_loopback() {
        assert_eq!(normalize("not a client ip: ::1"), "not a client ip: {ip}");
    }

    #[test]
    fn ipv6_full() {
        assert_eq!(
            normalize("addr 2001:db8::1 unreachable"),
            "addr {ip} unreachable"
        );
    }

    #[test]
    fn ipv6_with_port() {
        assert_eq!(normalize("binding to [::1]:53"), "binding to {ip}:{port}");
        assert_eq!(
            normalize("src [2001:db8::1]:1234 dst [::1]:53"),
            "src {ip}:{port} dst {ip}:{port}"
        );
    }

    #[test]
    fn ipv6_mapped_ipv4() {
        assert_eq!(normalize("addr ::ffff:192.0.2.1"), "addr {ip}");
    }

    // --- UUID ---

    #[test]
    fn uuid_in_message() {
        assert_eq!(
            normalize("resource 12345678-abcd-1234-abcd-1234567890ab not found"),
            "resource {uuid} not found"
        );
    }

    #[test]
    fn uuid_not_matched_when_too_short() {
        // Only 4 groups instead of 5 — does not match UUID, but does match dash-separated hex.
        assert_eq!(normalize("id abcdefab-abcd-abcd-abcd"), "id {hex}");
    }

    #[test]
    fn dash_separated_hex() {
        assert_eq!(normalize("trans ab12cd34-ef56-7890"), "trans {hex}");
    }

    // --- standalone numbers ---

    #[test]
    fn number_standalone() {
        assert_eq!(normalize("context 9"), "context {num}");
        assert_eq!(normalize("port 8080 is busy"), "port {num} is busy");
    }

    #[test]
    fn number_not_matched_in_identifier() {
        assert_eq!(normalize("error_type_42"), "error_type_42");
    }

    #[test]
    fn number_not_matched_before_dot() {
        // "1.2" is not an IPv4 but should not split into "{num}.{num}" either.
        assert_eq!(normalize("version 1.2"), "version 1.2");
    }

    // --- hex strings ---

    #[test]
    fn hex_string_key() {
        // 64-char hex string (WireGuard public key length); too long to be a UUID.
        assert_eq!(
            normalize(
                "No connection for key \
                 deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
            ),
            "No connection for key {hex}"
        );
    }

    #[test]
    fn hex_string_too_short_not_matched() {
        // 7 hex chars — below the 8-char threshold.
        assert_eq!(normalize("id deadbee"), "id deadbee");
    }

    #[test]
    fn pure_decimal_not_matched_as_hex() {
        // All digits, no a-f — stays as {num}, not {hex}.
        assert_eq!(normalize("code 12345678"), "code {num}");
    }

    // --- common TunnelError messages ---

    #[test]
    fn not_client_ip_message() {
        assert_eq!(
            normalize("Not a client IP: 192.168.1.1"),
            "Not a client IP: {ip}"
        );
        assert_eq!(
            normalize("Not a client IP: fe80::1"),
            "Not a client IP: {ip}"
        );
    }

    #[test]
    fn failed_to_handle_network_packet() {
        assert_eq!(
            normalize("Failed to handle packet from network (src 1.2.3.4:8080 dst 5.6.7.8:9090)"),
            "Failed to handle packet from network (src {ip}:{port} dst {ip}:{port})"
        );
    }

    #[test]
    fn traffic_not_allowed_message() {
        assert_eq!(
            normalize("Traffic to/from this resource IP is not allowed: 10.0.0.1"),
            "Traffic to/from this resource IP is not allowed: {ip}"
        );
    }
}

pub mod metrics {
    use std::{ops::ControlFlow, time::Duration};

    use opentelemetry::{
        KeyValue,
        metrics::{Counter, Gauge},
    };

    use crate::otel::QueueLength;

    pub fn network_packet_dropped() -> Counter<u64> {
        opentelemetry::global::meter("connlib")
            .u64_counter("network.packet.dropped")
            .with_description("Count of packets that are dropped or discarded")
            .with_unit("{packet}")
            .build()
    }

    pub fn tunnel_errors() -> Counter<u64> {
        opentelemetry::global::meter("connlib")
            .u64_counter("tunnel.error")
            .with_description("Number of errors encountered while processing a packet batch.")
            .with_unit("{error}")
            .build()
    }

    pub fn connection_count() -> Gauge<u64> {
        opentelemetry::global::meter("connlib")
            .u64_gauge("tunnel.connection.count")
            .with_description("Number of connections by the network path in use.")
            .with_unit("{connection}")
            .build()
    }

    pub async fn periodic_system_queue_length<const N: usize>(
        queue: impl QueueLength,
        attributes: [KeyValue; N],
    ) {
        let gauge = opentelemetry::global::meter("connlib")
            .u64_gauge("system.queue.length")
            .with_description("The length of a queue.")
            .build();

        periodic_gauge(
            gauge,
            |gauge| {
                let len = match queue.queue_length() {
                    Some(len) => len,
                    None => return ControlFlow::Break(()),
                };

                gauge.record(len, &attributes);

                ControlFlow::Continue(())
            },
            Duration::from_secs(1),
        )
        .await;
    }

    pub async fn periodic_gauge<T>(
        gauge: Gauge<T>,
        callback: impl Fn(&Gauge<T>) -> ControlFlow<(), ()>,
        interval: Duration,
    ) {
        while callback(&gauge).is_continue() {
            tokio::time::sleep(interval).await;
        }
    }
}

pub trait QueueLength: Send + Sync + 'static {
    fn queue_length(&self) -> Option<u64>;
}

impl<T> QueueLength for tokio::sync::mpsc::WeakSender<T>
where
    T: Send + Sync + 'static,
{
    fn queue_length(&self) -> Option<u64> {
        let sender = self.upgrade()?;
        let len = sender.max_capacity() - sender.capacity();

        Some(len as u64)
    }
}

pub fn default_resource_with<const N: usize>(attributes: [KeyValue; N]) -> Resource {
    Resource::builder_empty()
        .with_detector(Box::new(TelemetryResourceDetector))
        .with_detector(Box::new(OsResourceDetector))
        .with_detector(Box::new(EnvResourceDetector::new()))
        .with_attributes(attributes)
        .build()
}

pub struct OsResourceDetector;

impl ResourceDetector for OsResourceDetector {
    fn detect(&self) -> Resource {
        Resource::builder_empty()
            .with_attribute(KeyValue::new("os.type", std::env::consts::OS))
            .build()
    }
}
