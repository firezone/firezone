//! OpenTelemetry metric definitions shared across the relay's datapaths.
//!
//! Names and units follow the OpenTelemetry semantic conventions (dot-namespaced
//! names, UCUM units), consistent with `connlib`.

use opentelemetry::KeyValue;
use opentelemetry::metrics::Histogram;

/// Histogram of relayed packet sizes, recorded on both the userspace and the XDP datapath.
///
/// Both call-sites build the instrument from this function so the metric definition
/// (name, unit, buckets) stays identical; tag each measurement with
/// [`datapath_userspace`] or [`datapath_xdp`] to tell the two datapaths apart.
pub(crate) fn packet_size() -> Histogram<u64> {
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

/// `relay.datapath = userspace`: relayed by the userspace TURN server.
pub(crate) fn datapath_userspace() -> KeyValue {
    KeyValue::new("relay.datapath", "userspace")
}

/// `relay.datapath = xdp`: relayed by the in-kernel XDP program.
pub(crate) fn datapath_xdp() -> KeyValue {
    KeyValue::new("relay.datapath", "xdp")
}
