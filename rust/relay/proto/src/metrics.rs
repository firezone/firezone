//! OpenTelemetry metric definitions shared across the relay's datapaths.
//!
//! Names and units follow the OpenTelemetry semantic conventions (dot-namespaced
//! names, UCUM units), consistent with `connlib`.

use opentelemetry::KeyValue;
use opentelemetry::metrics::{Counter, Histogram, UpDownCounter};

/// Up/down counter of currently active allocations.
pub fn active_allocations() -> UpDownCounter<i64> {
    opentelemetry::global::meter("relay")
        .i64_up_down_counter("relay.active_allocations")
        .with_description("The number of active allocations")
        .with_unit("{allocation}")
        .build()
}

/// Counter of responses sent by the relay.
pub fn responses() -> Counter<u64> {
    opentelemetry::global::meter("relay")
        .u64_counter("relay.responses")
        .with_description("The number of responses")
        .with_unit("{response}")
        .build()
}

/// Histogram of relayed packet sizes, recorded on both the userspace and the XDP datapath.
///
/// Both call-sites build the instrument from this function so the metric definition
/// (name, unit, buckets) stays identical; tag each measurement with
/// `datapath_userspace` or `datapath_xdp` to tell the two datapaths apart.
pub fn packet_size() -> Histogram<u64> {
    opentelemetry::global::meter("relay")
        .u64_histogram("relay.packet.size")
        .with_description("Size of relayed packets")
        .with_unit("By")
        .with_boundaries(vec![
            100.0, 200.0, 300.0, 400.0, 500.0, 600.0, 700.0, 800.0, 900.0, 1000.0, 1100.0, 1200.0,
            1300.0, 1400.0, 1500.0,
        ])
        .build()
}

/// Histogram of the time the eBPF XDP program spent processing one relayed packet.
pub fn xdp_processing_duration() -> Histogram<u64> {
    opentelemetry::global::meter("relay")
        .u64_histogram("relay.xdp.processing.duration")
        .with_description("Time the eBPF XDP program spent processing one relayed packet")
        .with_unit("ns")
        .with_boundaries(vec![
            50.0, 100.0, 200.0, 500.0, 1_000.0, 2_000.0, 5_000.0, 10_000.0, 20_000.0, 50_000.0,
            100_000.0,
        ])
        .build()
}

/// `relay.datapath = userspace`: relayed by the userspace TURN server.
pub fn datapath_userspace() -> KeyValue {
    KeyValue::new("relay.datapath", "userspace")
}

/// `relay.datapath = xdp`: relayed by the in-kernel XDP program.
pub fn datapath_xdp() -> KeyValue {
    KeyValue::new("relay.datapath", "xdp")
}

/// Counter of relayed packets by incoming IP version and ECN codepoint.
/// Includes Not-ECT packets to measure the proportion of ECN-capable traffic.
pub fn packets() -> Counter<u64> {
    opentelemetry::global::meter("relay")
        .u64_counter("relay.packets")
        .with_description("The number of relayed packets")
        .with_unit("{packet}")
        .build()
}

/// Incoming OSI network-layer protocol, using OpenTelemetry's `network.type` convention.
pub fn network_type(ip_version: u8) -> KeyValue {
    KeyValue::new(
        "network.type",
        match ip_version {
            4 => "ipv4",
            6 => "ipv6",
            _ => "unknown",
        },
    )
}

/// Incoming IP ECN codepoint. `network.ecn` is a custom attribute, not an OTel standard.
pub fn network_ecn(ecn: u8) -> KeyValue {
    KeyValue::new(
        "network.ecn",
        match ecn {
            0 => "not_ect",
            1 => "ect1",
            2 => "ect0",
            3 => "ce",
            _ => "unknown",
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_network_types() {
        for (version, expected) in [(4, "ipv4"), (6, "ipv6"), (0, "unknown")] {
            assert_eq!(
                network_type(version),
                KeyValue::new("network.type", expected)
            );
        }
    }

    #[test]
    fn maps_ecn_codepoints() {
        for (ecn, expected) in [
            (0, "not_ect"),
            (1, "ect1"),
            (2, "ect0"),
            (3, "ce"),
            (4, "unknown"),
        ] {
            assert_eq!(network_ecn(ecn), KeyValue::new("network.ecn", expected));
        }
    }
}
