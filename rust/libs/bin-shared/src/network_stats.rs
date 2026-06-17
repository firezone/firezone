//! Periodic sampling of host network statistics reported by the OS.
//!
//! Two sources are sampled periodically and reported as increments on
//! OpenTelemetry counters in the `system.network.*` namespace:
//!
//! - Per-interface error and drop counters, via rtnetlink (`IFLA_STATS64`),
//!   tagged with the interface name and direction.
//! - UDP receive/send buffer errors, from `/proc/net/snmp` and
//!   `/proc/net/snmp6`, tagged with direction and IP version. These are
//!   host-wide UDP MIB counters, not specific to Firezone's sockets.
//!
//! Interface directions are from the interface's point of view (`receive` =
//! ingress, `transmit` = egress) — the inverse of connlib's own
//! `connlib.network.*` counters for the TUN device.
//!
//! Loopback and common virtual/container interfaces (Docker, veth, bridges) are
//! skipped to keep cardinality and noise down.

/// Reports host network counters until the future is dropped.
///
/// Meant to be spawned as a background task. Implemented on Linux via rtnetlink
/// and `/proc`; a no-op on other platforms.
#[cfg(target_os = "linux")]
pub async fn run() {
    linux::run().await;
}

#[cfg(not(target_os = "linux"))]
#[expect(
    clippy::unused_async,
    reason = "Mirrors the Linux signature so callers can spawn it uniformly."
)]
pub async fn run() {}

#[cfg(target_os = "linux")]
mod linux {
    use anyhow::{Context as _, Result};
    use futures::TryStreamExt as _;
    use netlink_packet_route::link::{LinkAttribute, LinkFlags, Stats64};
    use opentelemetry::KeyValue;
    use opentelemetry::metrics::Counter;
    use rtnetlink::{Handle, new_connection};
    use std::collections::{HashMap, HashSet};
    use std::time::Duration;
    use telemetry::otel;

    /// How often the OS counters are sampled.
    const POLL_INTERVAL: Duration = Duration::from_secs(60);

    pub(super) async fn run() {
        let (connection, handle, _messages) = match new_connection() {
            Ok(connection) => connection,
            Err(e) => {
                tracing::warn!("Failed to open netlink connection for interface statistics: {e}");
                return;
            }
        };

        // Drive the netlink connection alongside the sampling loop on this task
        // rather than spawning it. `sample_forever` never returns, so this
        // resolves only when the connection ends, which then stops sampling too.
        // (`select` needs `Unpin`, hence the `Box::pin`.)
        let connection = Box::pin(connection);
        let sampling = Box::pin(sample_forever(handle));
        futures::future::select(connection, sampling).await;

        tracing::debug!("Netlink connection ended; stopped sampling interface statistics");
    }

    async fn sample_forever(handle: Handle) {
        let instruments = Instruments::new();
        let mut interfaces = HashMap::new();
        let mut udp = UdpState::default();
        let mut interval = tokio::time::interval(POLL_INTERVAL);

        loop {
            interval.tick().await;

            if let Err(e) = sample_interfaces(&handle, &instruments, &mut interfaces).await {
                tracing::debug!("Failed to sample interface statistics: {e:#}");
            }

            sample_udp(&instruments.udp_buffer_errors, &mut udp).await;
        }
    }

    /// Samples every interface once and records the increment since the last sample.
    #[expect(
        clippy::wildcard_enum_match_arm,
        reason = "We don't want to match all attributes."
    )]
    async fn sample_interfaces(
        handle: &Handle,
        instruments: &Instruments,
        previous: &mut HashMap<u32, Stats64>,
    ) -> Result<()> {
        let mut links = handle.link().get().execute();
        let mut seen = HashSet::new();

        while let Some(link) = links
            .try_next()
            .await
            .context("Failed to read link from netlink")?
        {
            let index = link.header.index;

            let Some(name) = link.attributes.iter().find_map(|attr| match attr {
                LinkAttribute::IfName(name) => Some(name.clone()),
                _ => None,
            }) else {
                continue;
            };

            // Loopback and virtual/container interfaces are noise; skip them.
            if link.header.flags.contains(LinkFlags::Loopback) || is_virtual(&name) {
                continue;
            }

            let Some(current) = link.attributes.iter().find_map(|attr| match attr {
                LinkAttribute::Stats64(stats) => Some(*stats),
                _ => None,
            }) else {
                continue;
            };

            seen.insert(index);

            // The first sample for an interface only establishes the baseline;
            // reporting it would attribute the entire since-boot total to one interval.
            let Some(previous) = previous.insert(index, current) else {
                continue;
            };

            record_interface(instruments, &name, previous, current);
        }

        // Forget interfaces that have gone away so a reused index restarts from a fresh baseline.
        previous.retain(|index, _| seen.contains(index));

        Ok(())
    }

    fn record_interface(
        instruments: &Instruments,
        name: &str,
        previous: Stats64,
        current: Stats64,
    ) {
        let receive = [
            KeyValue::new("network.interface.name", name.to_owned()),
            otel::attr::network_io_direction_receive(),
        ];
        let transmit = [
            KeyValue::new("network.interface.name", name.to_owned()),
            otel::attr::network_io_direction_transmit(),
        ];

        record_delta(
            &instruments.errors,
            &receive,
            previous.rx_errors,
            current.rx_errors,
        );
        record_delta(
            &instruments.errors,
            &transmit,
            previous.tx_errors,
            current.tx_errors,
        );
        record_delta(
            &instruments.dropped,
            &receive,
            previous.rx_dropped,
            current.rx_dropped,
        );
        record_delta(
            &instruments.dropped,
            &transmit,
            previous.tx_dropped,
            current.tx_dropped,
        );
    }

    /// Samples the host-wide UDP send/receive buffer error counters for both IP versions.
    async fn sample_udp(counter: &Counter<u64>, previous: &mut UdpState) {
        if let Some(current) = tokio::fs::read_to_string("/proc/net/snmp")
            .await
            .ok()
            .as_deref()
            .and_then(parse_snmp_udp)
        {
            record_udp(
                counter,
                otel::attr::network_type_ipv4(),
                previous.v4.replace(current),
                current,
            );
        }

        if let Some(current) = tokio::fs::read_to_string("/proc/net/snmp6")
            .await
            .ok()
            .as_deref()
            .and_then(parse_snmp6_udp)
        {
            record_udp(
                counter,
                otel::attr::network_type_ipv6(),
                previous.v6.replace(current),
                current,
            );
        }
    }

    fn record_udp(
        counter: &Counter<u64>,
        network_type: KeyValue,
        previous: Option<UdpBufferErrors>,
        current: UdpBufferErrors,
    ) {
        // The first sample establishes the baseline; see `sample_interfaces`.
        let Some(previous) = previous else {
            return;
        };

        record_delta(
            counter,
            &[
                otel::attr::network_io_direction_receive(),
                network_type.clone(),
            ],
            previous.receive,
            current.receive,
        );
        record_delta(
            counter,
            &[otel::attr::network_io_direction_transmit(), network_type],
            previous.transmit,
            current.transmit,
        );
    }

    /// Parses the `Udp:` line of `/proc/net/snmp` (IPv4).
    ///
    /// The file pairs a header row of column names with a row of values, both
    /// prefixed `Udp:`; columns are matched by name to tolerate ordering changes.
    fn parse_snmp_udp(contents: &str) -> Option<UdpBufferErrors> {
        let mut udp = contents.lines().filter(|line| line.starts_with("Udp:"));
        let columns = udp.next()?.split_whitespace().collect::<Vec<_>>();
        let values = udp.next()?.split_whitespace().collect::<Vec<_>>();

        let value_of = |field: &str| -> Option<u64> {
            let index = columns.iter().position(|&column| column == field)?;
            values.get(index)?.parse().ok()
        };

        Some(UdpBufferErrors {
            receive: value_of("RcvbufErrors")?,
            transmit: value_of("SndbufErrors")?,
        })
    }

    /// Parses the `Udp6*` lines of `/proc/net/snmp6` (IPv6), one `name value` pair per line.
    fn parse_snmp6_udp(contents: &str) -> Option<UdpBufferErrors> {
        let value_of = |field: &str| -> Option<u64> {
            contents.lines().find_map(|line| {
                let (name, value) = line.split_once(char::is_whitespace)?;

                if name == field {
                    value.trim().parse().ok()
                } else {
                    None
                }
            })
        };

        Some(UdpBufferErrors {
            receive: value_of("Udp6RcvbufErrors")?,
            transmit: value_of("Udp6SndbufErrors")?,
        })
    }

    /// Records the increment of one cumulative counter since the last sample.
    fn record_delta(counter: &Counter<u64>, attributes: &[KeyValue], previous: u64, current: u64) {
        let increment = delta(previous, current);

        if increment > 0 {
            counter.add(increment, attributes);
        }
    }

    /// The increment between two samples of a cumulative counter.
    ///
    /// A current value below the previous one means the kernel counter was reset
    /// (e.g. the interface was recreated), so the current value is the increment.
    fn delta(previous: u64, current: u64) -> u64 {
        current.checked_sub(previous).unwrap_or(current)
    }

    /// Whether `name` is a virtual or container interface whose counters are noise.
    ///
    /// A name-prefix heuristic covering the common cases (Docker, container veth
    /// pairs, Docker/libvirt bridges); loopback is handled separately via flags.
    fn is_virtual(name: &str) -> bool {
        const PREFIXES: [&str; 4] = ["docker", "veth", "br-", "virbr"];

        PREFIXES.iter().any(|prefix| name.starts_with(prefix))
    }

    struct Instruments {
        errors: Counter<u64>,
        dropped: Counter<u64>,
        udp_buffer_errors: Counter<u64>,
    }

    impl Instruments {
        fn new() -> Self {
            Self {
                errors: otel_instruments::system_network_errors(),
                dropped: otel_instruments::system_network_dropped(),
                udp_buffer_errors: otel_instruments::system_network_udp_buffer_errors(),
            }
        }
    }

    /// Last-seen UDP buffer error counters per IP version, for delta computation.
    #[derive(Default)]
    struct UdpState {
        v4: Option<UdpBufferErrors>,
        v6: Option<UdpBufferErrors>,
    }

    #[derive(Default, Clone, Copy)]
    struct UdpBufferErrors {
        receive: u64,
        transmit: u64,
    }

    #[cfg(test)]
    mod tests {
        use super::{UdpBufferErrors, delta, is_virtual, parse_snmp_udp, parse_snmp6_udp};

        #[test]
        fn delta_is_difference_when_counter_increases() {
            assert_eq!(delta(10, 25), 15);
        }

        #[test]
        fn delta_is_zero_when_counter_unchanged() {
            assert_eq!(delta(25, 25), 0);
        }

        #[test]
        fn delta_is_current_value_when_counter_resets() {
            assert_eq!(delta(100, 30), 30);
        }

        #[test]
        fn virtual_interfaces_are_filtered() {
            assert!(is_virtual("docker0"));
            assert!(is_virtual("veth1a2b3c"));
            assert!(is_virtual("br-9f3a"));
            assert!(is_virtual("virbr0"));
        }

        #[test]
        fn real_interfaces_are_kept() {
            assert!(!is_virtual("eth0"));
            assert!(!is_virtual("enp3s0"));
            assert!(!is_virtual("tun-firezone"));
            assert!(!is_virtual("wg0"));
            assert!(!is_virtual("br0"));
        }

        #[test]
        fn parses_udp_buffer_errors_from_snmp() {
            let contents = "\
Ip: Forwarding DefaultTTL InReceives
Ip: 1 64 1000
Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors
Udp: 1000 2 3 1100 7 9
UdpLite: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors
UdpLite: 0 0 0 0 0 0
";
            let parsed = parse_snmp_udp(contents).expect("a Udp line");

            assert_eq!(parsed.receive, 7);
            assert_eq!(parsed.transmit, 9);
        }

        #[test]
        fn parses_udp_buffer_errors_from_snmp6() {
            let contents = "\
Udp6InDatagrams                 \t500
Udp6RcvbufErrors                \t4
Udp6SndbufErrors                \t5
UdpLite6RcvbufErrors            \t99
";
            let parsed = parse_snmp6_udp(contents).expect("a Udp6 line");

            assert_eq!(parsed.receive, 4);
            assert_eq!(parsed.transmit, 5);
        }

        #[test]
        fn snmp_parsers_handle_missing_fields() {
            assert!(parse_snmp_udp("Udp: InDatagrams NoPorts\nUdp: 1 2\n").is_none());
            assert!(parse_snmp6_udp("Udp6InDatagrams\t1\n").is_none());
        }

        #[test]
        fn udp_buffer_errors_default_to_zero() {
            let errors = UdpBufferErrors::default();

            assert_eq!(errors.receive, 0);
            assert_eq!(errors.transmit, 0);
        }
    }
}
