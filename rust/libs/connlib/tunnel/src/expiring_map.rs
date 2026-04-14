use core::fmt;
use std::{
    collections::{BTreeMap, HashMap, VecDeque, btree_map},
    hash::Hash,
    mem,
    time::{Duration, Instant},
};

/// A map that automatically removes entries after a given expiration time.
#[derive(Debug)]
pub struct ExpiringMap<K, V> {
    inner: HashMap<K, Entry<V>>,
    expiration: BTreeMap<Instant, Vec<K>>,

    events: VecDeque<Event<K, V>>,
}

impl<K, V> Default for ExpiringMap<K, V> {
    fn default() -> Self {
        Self {
            inner: HashMap::default(),
            expiration: BTreeMap::default(),
            events: VecDeque::default(),
        }
    }
}

impl<K, V> ExpiringMap<K, V>
where
    K: Hash + Eq + Clone + fmt::Debug,
    V: fmt::Debug,
{
    pub fn insert(
        &mut self,
        key: K,
        value: V,
        now: Instant,
        ttl: Duration,
    ) -> Option<(V, Instant, Instant)> {
        let expiration = now + ttl;
        let entry = Entry {
            value,
            inserted_at: now,
            expires_at: expiration,
        };
        let old_entry = self.inner.insert(key.clone(), entry);

        // Remove the key from its previous expiration bucket to prevent
        // `handle_timeout` from evicting the renewed entry early.
        if let Some(ref old) = old_entry {
            remove_from_expiration_bucket(&mut self.expiration, &key, old.expires_at);
        }

        self.expiration.entry(expiration).or_default().push(key);

        old_entry.map(|e| (e.value, e.inserted_at, e.expires_at))
    }

    pub fn get(&self, key: &K) -> Option<&Entry<V>> {
        self.inner.get(key)
    }

    #[cfg(test)]
    pub fn remove(&mut self, key: &K) -> Option<Entry<V>> {
        let entry = self.inner.remove(key)?;
        remove_from_expiration_bucket(&mut self.expiration, key, entry.expires_at);
        Some(entry)
    }

    /// Retains only the entries for which `predicate` returns `true`.
    ///
    /// Removed entries do NOT produce [`Event::EntryExpired`].
    #[allow(dead_code)] // TODO: remove when dynamic device pool lands
    pub fn retain<F>(&mut self, mut predicate: F)
    where
        F: FnMut(&K, &V) -> bool,
    {
        for (key, entry) in self
            .inner
            .extract_if(|k, entry| !predicate(k, &entry.value))
        {
            remove_from_expiration_bucket(&mut self.expiration, &key, entry.expires_at);
        }
    }

    pub fn poll_timeout(&self) -> Option<Instant> {
        self.expiration.keys().next().cloned()
    }

    pub fn clear(&mut self) {
        self.inner.clear();
        self.expiration.clear();
        self.events.clear();
    }

    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        let mut not_yet_expired = self.expiration.split_off(&now);
        let now_entry = not_yet_expired.remove(&now);

        for key in mem::replace(&mut self.expiration, not_yet_expired)
            .into_values()
            .chain(now_entry)
            .flatten()
        {
            let Some(entry) = self.inner.remove(&key) else {
                continue;
            };

            self.events.push_back(Event::EntryExpired {
                key,
                value: entry.value,
            });
        }
    }

    pub fn poll_event(&mut self) -> Option<Event<K, V>> {
        self.events.pop_front()
    }
}

fn remove_from_expiration_bucket<K: Eq>(
    expiration: &mut BTreeMap<Instant, Vec<K>>,
    key: &K,
    expires_at: Instant,
) {
    if let btree_map::Entry::Occupied(mut bucket) = expiration.entry(expires_at) {
        let keys = bucket.get_mut();
        if let Some(pos) = keys.iter().position(|k| k == key) {
            keys.swap_remove(pos);
        }
        if bucket.get().is_empty() {
            bucket.remove();
        }
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct Entry<V> {
    pub value: V,
    pub inserted_at: Instant,
    pub expires_at: Instant,
}

#[derive(Debug)]
pub enum Event<K, V> {
    EntryExpired { key: K, value: V },
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn poll_timeout_returns_next_expiration() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("key1", "value1", now, Duration::from_secs(1));
        map.insert("key2", "value2", now, Duration::from_secs(2));

        assert_eq!(map.poll_timeout(), Some(now + Duration::from_secs(1)));
    }

    #[test]
    fn handle_timeout_removes_expired_entries() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("key1", "value1", now, Duration::from_secs(1));
        map.insert("key2", "value2", now, Duration::from_secs(2));

        map.handle_timeout(now + Duration::from_secs(1));

        assert_eq!(map.get(&"key1"), None);
        assert_eq!(map.get(&"key2").unwrap().value, "value2");
    }

    #[test]
    fn removing_item_updates_expiration() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("key1", "value1", now, Duration::from_secs(1));
        map.insert("key2", "value2", now, Duration::from_secs(2));

        map.remove(&"key1");

        assert_eq!(map.poll_timeout(), Some(now + Duration::from_secs(2)));
    }

    #[test]
    fn expiring_all_items_empties_map() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("key1", "value1", now, Duration::from_secs(1));
        map.insert("key2", "value2", now, Duration::from_secs(1));
        map.insert("key3", "value3", now, Duration::from_secs(1));
        map.insert("key4", "value4", now, Duration::from_secs(1));
        map.insert("key5", "value5", now, Duration::from_secs(1));

        while let Some(timeout) = map.poll_timeout() {
            map.handle_timeout(timeout);
        }

        assert!(map.is_empty())
    }

    #[test]
    fn can_handle_multiple_items_at_same_timestamp() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("key1", "value1", now, Duration::from_secs(1));
        map.insert("key2", "value2", now, Duration::from_secs(1));
        map.insert("key3", "value3", now, Duration::from_secs(1));

        map.handle_timeout(now + Duration::from_secs(1));

        assert!(map.is_empty())
    }

    #[test]
    fn reinsert_with_new_ttl_does_not_evict_early() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("key", "v1", now, Duration::from_secs(1));
        // Re-insert the same key with a longer TTL.
        map.insert("key", "v2", now, Duration::from_secs(3));

        // When the original expiration fires, the entry must survive.
        map.handle_timeout(now + Duration::from_secs(1));
        assert_eq!(
            map.get(&"key").unwrap().value,
            "v2",
            "re-inserted key must not be evicted by the old expiration bucket"
        );

        // It should expire at the new TTL.
        map.handle_timeout(now + Duration::from_secs(3));
        assert!(map.get(&"key").is_none());
    }

    #[test]
    fn reinsert_with_shorter_ttl_expires_at_new_time() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("key", "v1", now, Duration::from_secs(5));
        map.insert("key", "v2", now, Duration::from_secs(1));

        map.handle_timeout(now + Duration::from_secs(1));
        assert!(
            map.get(&"key").is_none(),
            "entry must expire at the shorter TTL"
        );

        // The old 5s bucket must be gone too.
        assert_eq!(map.poll_timeout(), None);
    }

    #[test]
    fn reinsert_with_same_ttl_does_not_duplicate_expiration_entry() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("key", "v1", now, Duration::from_secs(1));
        map.insert("key", "v2", now, Duration::from_secs(1));

        map.handle_timeout(now + Duration::from_secs(1));
        assert!(map.get(&"key").is_none());
        assert_eq!(
            map.poll_timeout(),
            None,
            "no stale expiration buckets should remain"
        );
    }

    #[test]
    fn retain_removing_everything_leaves_empty_map() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("a", 1, now, Duration::from_secs(1));
        map.insert("b", 2, now, Duration::from_secs(2));

        map.retain(|_, _| false);

        assert!(map.is_empty());
        assert_eq!(map.poll_timeout(), None, "expiration index must be empty");
    }

    #[test]
    fn retain_removing_nothing_preserves_all_entries() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("a", 1, now, Duration::from_secs(1));
        map.insert("b", 2, now, Duration::from_secs(2));

        map.retain(|_, _| true);

        assert_eq!(map.get(&"a").unwrap().value, 1);
        assert_eq!(map.get(&"b").unwrap().value, 2);
        assert_eq!(map.poll_timeout(), Some(now + Duration::from_secs(1)));
    }

    #[test]
    fn retain_multiple_entries_in_same_expiration_bucket() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("keep", 1, now, Duration::from_secs(1));
        map.insert("drop1", 2, now, Duration::from_secs(1));
        map.insert("drop2", 3, now, Duration::from_secs(1));

        map.retain(|k, _| *k == "keep");

        assert_eq!(map.get(&"keep").unwrap().value, 1);
        assert_eq!(map.get(&"drop1"), None);
        assert_eq!(map.get(&"drop2"), None);

        // The bucket should still exist for "keep".
        assert_eq!(map.poll_timeout(), Some(now + Duration::from_secs(1)));
    }

    #[test]
    fn retain_drops_non_matching_entries_and_updates_expiration_index() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("keep", "value1", now, Duration::from_secs(1));
        map.insert("drop", "value2", now, Duration::from_secs(2));

        map.retain(|k, _| *k == "keep");

        assert_eq!(map.get(&"keep").unwrap().value, "value1");
        assert_eq!(map.get(&"drop"), None);
        assert_eq!(
            map.poll_timeout(),
            Some(now + Duration::from_secs(1)),
            "expiration index must drop the removed entry"
        );
    }

    #[test]
    fn clear_resets_expiration_index() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("a", 1, now, Duration::from_secs(1));
        map.insert("b", 2, now, Duration::from_secs(2));

        map.clear();

        assert!(map.is_empty());
        assert_eq!(map.poll_timeout(), None, "expiration index must be cleared");
    }
}
