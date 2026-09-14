use std::{
    collections::BTreeMap,
    fmt,
    time::{Duration, Instant},
};

/// Remote candidates for connections we have not been told about (yet).
///
/// A new connection and its candidates are signalled independently through the portal,
/// so a remote's candidates can overtake the message that creates the connection locally.
/// They are held here until the connection is created or they expire.
pub(crate) struct BufferedCandidates<TId> {
    inner: BTreeMap<TId, Vec<(Instant, String)>>,
}

impl<TId> BufferedCandidates<TId>
where
    TId: Copy + Ord + fmt::Display,
{
    const TIMEOUT: Duration = Duration::from_secs(10);
    const MAX_PER_CONNECTION: usize = 32;

    pub(crate) fn push(&mut self, cid: TId, candidate: String, now: Instant) {
        let candidates = self.inner.entry(cid).or_default();

        if candidates.len() >= Self::MAX_PER_CONNECTION {
            let (_, dropped) = candidates.remove(0);

            tracing::debug!(%cid, candidate = %dropped, "Dropping oldest buffered candidate");
        }

        candidates.push((now, candidate));
    }

    /// Removes a buffered candidate, returning whether it was present.
    pub(crate) fn remove(&mut self, cid: &TId, candidate: &str) -> bool {
        let Some(candidates) = self.inner.get_mut(cid) else {
            return false;
        };

        let num_removed = candidates.extract_if(.., |(_, c)| c == candidate).count();

        if candidates.is_empty() {
            self.inner.remove(cid);
        }

        num_removed > 0
    }

    pub(crate) fn drain(&mut self, cid: &TId) -> impl Iterator<Item = String> + use<TId> {
        self.inner
            .remove(cid)
            .into_iter()
            .flatten()
            .map(|(_, candidate)| candidate)
    }

    pub(crate) fn clear(&mut self) {
        self.inner.clear();
    }

    pub(crate) fn poll_timeout(&self) -> Option<(Instant, &'static str)> {
        self.inner
            .values()
            .filter_map(|candidates| candidates.first())
            .map(|(received_at, _)| (*received_at + Self::TIMEOUT, "buffered candidates"))
            .min_by_key(|(instant, _)| *instant)
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        for (cid, candidates) in self.inner.iter_mut() {
            for (_, candidate) in candidates.extract_if(.., |(received_at, _)| {
                now.duration_since(*received_at) >= Self::TIMEOUT
            }) {
                tracing::debug!(%cid, %candidate, "Discarding buffered candidate for unknown connection");
            }
        }

        self.inner
            .extract_if(.., |_, candidates| candidates.is_empty())
            .for_each(drop);
    }
}

impl<TId> Default for BufferedCandidates<TId> {
    fn default() -> Self {
        Self {
            inner: BTreeMap::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drains_candidates_in_order_of_arrival() {
        let mut buffer = BufferedCandidates::<u32>::default();
        let now = Instant::now();

        buffer.push(1, "first".to_owned(), now);
        buffer.push(1, "second".to_owned(), now);
        buffer.push(2, "other".to_owned(), now);

        assert_eq!(buffer.drain(&1).collect::<Vec<_>>(), ["first", "second"]);
        assert_eq!(buffer.drain(&1).count(), 0);
        assert_eq!(buffer.drain(&2).collect::<Vec<_>>(), ["other"]);
    }

    #[test]
    fn expires_candidates_after_timeout() {
        let mut buffer = BufferedCandidates::<u32>::default();
        let now = Instant::now();

        buffer.push(1, "early".to_owned(), now);
        buffer.push(1, "late".to_owned(), now + Duration::from_secs(5));

        let (timeout, _) = buffer.poll_timeout().unwrap();
        assert_eq!(timeout, now + BufferedCandidates::<u32>::TIMEOUT);

        buffer.handle_timeout(timeout);

        assert_eq!(buffer.drain(&1).collect::<Vec<_>>(), ["late"]);
        assert_eq!(buffer.poll_timeout(), None);
    }

    #[test]
    fn caps_candidates_per_connection() {
        let mut buffer = BufferedCandidates::<u32>::default();
        let now = Instant::now();

        for i in 0..=BufferedCandidates::<u32>::MAX_PER_CONNECTION {
            buffer.push(1, i.to_string(), now);
        }

        let candidates = buffer.drain(&1).collect::<Vec<_>>();
        assert_eq!(
            candidates.len(),
            BufferedCandidates::<u32>::MAX_PER_CONNECTION
        );
        assert_eq!(candidates.first().unwrap(), "1");
    }

    #[test]
    fn removes_candidate() {
        let mut buffer = BufferedCandidates::<u32>::default();
        let now = Instant::now();

        buffer.push(1, "candidate".to_owned(), now);

        assert!(buffer.remove(&1, "candidate"));
        assert!(!buffer.remove(&1, "candidate"));
        assert_eq!(buffer.poll_timeout(), None);
    }
}
