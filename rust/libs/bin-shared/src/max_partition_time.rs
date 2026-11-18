use std::time::Duration;

#[derive(clap::Args, Debug, Clone)]
pub struct MaxPartitionTimeArgs {
    /// Maximum length of time to retry connecting to the portal if we're having internet issues or
    /// it's down. Accepts human times. e.g. "5m" or "1h" or "30d".
    #[arg(short, long, env = "FIREZONE_MAX_PARTITION_TIME", value_parser = parse_duration)]
    pub max_partition_time: Option<Duration>,
}

/// Parses a duration in jiff's friendly format, counting days as 24 hours.
fn parse_duration(s: &str) -> anyhow::Result<Duration> {
    let span = s.parse::<jiff::Span>()?;
    let duration = span.to_duration(jiff::SpanRelativeTo::days_are_24_hours())?;
    let duration = Duration::try_from(duration)?;

    Ok(duration)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_duration_counts_days_as_24_hours() {
        assert_eq!(
            parse_duration("30d").unwrap(),
            Duration::from_secs(30 * 24 * 60 * 60)
        );
    }
}
