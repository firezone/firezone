use crate::pool::WIREGUARD_KEEP_ALIVE;
use std::time::Instant;

#[derive(Debug)]
pub struct ConnectionInfo {
    pub last_seen: Option<Instant>,

    /// When this instance of [`ConnectionInfo`] was created.
    pub generated_at: Instant,
}

impl ConnectionInfo {
    pub fn missed_keep_alives(&self) -> u64 {
        let Some(last_seen) = self.last_seen else {
            return 0;
        };

        let duration = self.generated_at.duration_since(last_seen);

        duration.as_secs() / WIREGUARD_KEEP_ALIVE as u64
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn no_missed_keep_alives_on_none() {
        let info = info(None);

        let missed_keep_alives = info.missed_keep_alives();

        assert_eq!(missed_keep_alives, 0);
    }

    #[test]
    fn more_than_5_sec_one_missed_keep_alive() {
        let info = info(Some(Instant::now() - Duration::from_secs(6)));

        let missed_keep_alives = info.missed_keep_alives();

        assert_eq!(missed_keep_alives, 1);
    }

    #[test]
    fn more_than_10_sec_two_missed_keep_alives() {
        let info = info(Some(Instant::now() - Duration::from_secs(11)));

        let missed_keep_alives = info.missed_keep_alives();

        assert_eq!(missed_keep_alives, 2);
    }

    fn info(last_seen: Option<Instant>) -> ConnectionInfo {
        ConnectionInfo {
            last_seen,
            generated_at: Instant::now(),
        }
    }
}
