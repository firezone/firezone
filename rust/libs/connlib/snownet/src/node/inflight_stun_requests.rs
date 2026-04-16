use std::{
    collections::{BTreeSet, HashMap},
    time::{Duration, Instant},
};

use is::stun::TransId;

/// For how long we will at most keep around an inflight STUN request ID.
const TTL: Duration = Duration::from_secs(10);

pub struct InflightStunRequests<TId> {
    inner: HashMap<TransId, TId>,
    expires_at: BTreeSet<(Instant, TransId)>,
}

impl<TId> Default for InflightStunRequests<TId> {
    fn default() -> Self {
        Self {
            inner: Default::default(),
            expires_at: Default::default(),
        }
    }
}

impl<TId> InflightStunRequests<TId>
where
    TId: PartialEq,
{
    pub fn add(&mut self, conn_id: TId, id: TransId, now: Instant) {
        self.inner.insert(id, conn_id);
        self.expires_at.insert((now + TTL, id));
    }

    pub fn remove(&mut self, id: TransId) -> Option<TId> {
        let id = self.inner.remove(&id)?;

        // We purposely don't clean up `expires_at` because it will get cleaned up in `handle_timeout` anyway.

        Some(id)
    }

    pub fn remove_by_conn_id(&mut self, id: TId) {
        for _ in self.inner.extract_if(|_, c| c == &id) {}

        // We purposely don't clean up `expires_at` because it will get cleaned up in `handle_timeout` anyway.
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        while let Some((expires, trans_id)) = self.expires_at.first() {
            if expires > &now {
                break;
            }

            self.inner.remove(trans_id);
            self.expires_at.pop_first();
        }
    }

    pub fn clear(&mut self) {
        self.inner.clear();
        self.expires_at.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_and_remove_returns_conn_id() {
        let mut requests = InflightStunRequests::default();
        let now = Instant::now();
        let id = TransId::new();

        requests.add(42u32, id, now);
        let result = requests.remove(id);

        assert_eq!(result, Some(42u32));
    }

    #[test]
    fn remove_unknown_id_returns_none() {
        let mut requests = InflightStunRequests::<u32>::default();
        let id = TransId::new();

        let result = requests.remove(id);

        assert_eq!(result, None);
    }

    #[test]
    fn remove_is_idempotent() {
        let mut requests = InflightStunRequests::default();
        let now = Instant::now();
        let id = TransId::new();

        requests.add(1u32, id, now);
        assert_eq!(requests.remove(id), Some(1u32));
        assert_eq!(requests.remove(id), None);
    }

    #[test]
    fn entry_not_expired_before_ttl() {
        let mut requests = InflightStunRequests::default();
        let now = Instant::now();
        let id = TransId::new();

        requests.add(1u32, id, now);
        requests.handle_timeout(now + TTL - Duration::from_millis(1));

        assert_eq!(requests.remove(id), Some(1u32));
    }

    #[test]
    fn entry_expired_after_ttl() {
        let mut requests = InflightStunRequests::default();
        let now = Instant::now();
        let id = TransId::new();

        requests.add(1u32, id, now);
        requests.handle_timeout(now + TTL + Duration::from_millis(1));

        assert_eq!(requests.remove(id), None);
    }

    #[test]
    fn entries_with_same_time_get_cleared_with_handle_timeout() {
        let mut requests = InflightStunRequests::default();
        let now = Instant::now();
        let id1 = TransId::new();
        let id2 = TransId::new();

        requests.add(1u32, id1, now);
        requests.add(2u32, id2, now);
        requests.handle_timeout(now + TTL + Duration::from_millis(1));

        assert_eq!(requests.remove(id1), None);
        assert_eq!(requests.remove(id2), None);
    }

    #[test]
    fn only_expired_entries_are_removed() {
        let mut requests = InflightStunRequests::default();
        let t0 = Instant::now();
        let early_id = TransId::new();
        let late_id = TransId::new();

        requests.add(1u32, early_id, t0);
        requests.add(2u32, late_id, t0 + Duration::from_secs(5));

        // Advance past the TTL of the first entry only.
        requests.handle_timeout(t0 + TTL + Duration::from_millis(1));

        assert_eq!(requests.remove(early_id), None);
        assert_eq!(requests.remove(late_id), Some(2u32));
    }

    #[test]
    fn remove_by_conn_id_removes_all_matching_entries() {
        let mut requests = InflightStunRequests::default();
        let now = Instant::now();
        let id_a = TransId::new();
        let id_b = TransId::new();
        let id_c = TransId::new();

        requests.add(1u32, id_a, now);
        requests.add(1u32, id_b, now);
        requests.add(2u32, id_c, now);

        requests.remove_by_conn_id(1u32);

        assert_eq!(requests.remove(id_a), None);
        assert_eq!(requests.remove(id_b), None);
        assert_eq!(requests.remove(id_c), Some(2u32));
    }

    #[test]
    fn remove_by_conn_id_is_noop_for_unknown_id() {
        let mut requests = InflightStunRequests::default();
        let now = Instant::now();
        let id = TransId::new();

        requests.add(1u32, id, now);
        requests.remove_by_conn_id(99u32);

        assert_eq!(requests.remove(id), Some(1u32));
    }
}
