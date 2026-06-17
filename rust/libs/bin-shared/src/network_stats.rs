//! Periodic sampling of per-interface network statistics reported by the OS.
//!
//! The kernel keeps cumulative per-interface counters (packets, bytes, errors,
//! drops). We sample them periodically and report the increments as
//! OpenTelemetry counters under the `system.network.*` namespace, tagged with
//! the interface name and direction.
//!
//! Directions are from the interface's point of view (`receive` = ingress,
//! `transmit` = egress). For the TUN device this is the inverse of connlib's
//! own `connlib.network.*` counters: a packet connlib writes into the TUN is an
//! ingress packet from the interface's perspective.

/// Spawns a background task reporting per-interface OS network counters.
///
/// Implemented on Linux via rtnetlink; a no-op on other platforms.
#[cfg(target_os = "linux")]
pub fn spawn() {
    tokio::spawn(linux::run());
}

#[cfg(not(target_os = "linux"))]
pub fn spawn() {}

#[cfg(target_os = "linux")]
mod linux {
    use anyhow::{Context as _, Result};
    use futures::TryStreamExt as _;
    use netlink_packet_route::link::{LinkAttribute, Stats64};
    use opentelemetry::KeyValue;
    use opentelemetry::metrics::{Counter, Meter};
    use rtnetlink::{Handle, new_connection};
    use std::collections::{HashMap, HashSet};
    use std::time::Duration;
    use telemetry::otel;

    /// How often the kernel's interface counters are sampled.
    const POLL_INTERVAL: Duration = Duration::from_secs(60);

    pub(super) async fn run() {
        let (connection, handle, _messages) = match new_connection() {
            Ok(connection) => connection,
            Err(e) => {
                tracing::warn!("Failed to open netlink connection for interface statistics: {e}");
                return;
            }
        };
        let _connection = tokio::spawn(connection);

        let instruments = Instruments::new();
        let mut previous = HashMap::new();
        let mut interval = tokio::time::interval(POLL_INTERVAL);

        loop {
            interval.tick().await;

            if let Err(e) = poll(&handle, &instruments, &mut previous).await {
                tracing::debug!("Failed to sample interface statistics: {e:#}");
            }
        }
    }

    /// Samples every interface once and records the increment since the last sample.
    #[expect(
        clippy::wildcard_enum_match_arm,
        reason = "We don't want to match all attributes."
    )]
    async fn poll(
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

            record(instruments, &name, previous, current);
        }

        // Forget interfaces that have gone away so a reused index restarts from a fresh baseline.
        previous.retain(|index, _| seen.contains(index));

        Ok(())
    }

    fn record(instruments: &Instruments, name: &str, previous: Stats64, current: Stats64) {
        let receive = [
            KeyValue::new("network.interface.name", name.to_owned()),
            otel::attr::network_io_direction_receive(),
        ];
        let transmit = [
            KeyValue::new("network.interface.name", name.to_owned()),
            otel::attr::network_io_direction_transmit(),
        ];

        record_delta(
            &instruments.packets,
            &receive,
            previous.rx_packets,
            current.rx_packets,
        );
        record_delta(
            &instruments.packets,
            &transmit,
            previous.tx_packets,
            current.tx_packets,
        );
        record_delta(
            &instruments.bytes,
            &receive,
            previous.rx_bytes,
            current.rx_bytes,
        );
        record_delta(
            &instruments.bytes,
            &transmit,
            previous.tx_bytes,
            current.tx_bytes,
        );
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

    struct Instruments {
        packets: Counter<u64>,
        bytes: Counter<u64>,
        errors: Counter<u64>,
        dropped: Counter<u64>,
    }

    impl Instruments {
        fn new() -> Self {
            let meter = meter();

            Self {
                packets: meter
                    .u64_counter("system.network.packets")
                    .with_description("Count of packets transferred on a network interface.")
                    .with_unit("{packet}")
                    .build(),
                bytes: meter
                    .u64_counter("system.network.io")
                    .with_description("Count of bytes transferred on a network interface.")
                    .with_unit("By")
                    .build(),
                errors: meter
                    .u64_counter("system.network.errors")
                    .with_description("Count of errors encountered on a network interface.")
                    .with_unit("{error}")
                    .build(),
                dropped: meter
                    .u64_counter("system.network.dropped")
                    .with_description("Count of packets dropped on a network interface.")
                    .with_unit("{packet}")
                    .build(),
            }
        }
    }

    fn meter() -> Meter {
        opentelemetry::global::meter("system")
    }

    #[cfg(test)]
    mod tests {
        use super::delta;

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
    }
}
