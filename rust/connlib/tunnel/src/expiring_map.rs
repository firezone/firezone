use core::fmt;
use std::{
    collections::{BTreeMap, HashMap, VecDeque},
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
        self.expiration.entry(expiration).or_default().push(key);

        old_entry.map(|e| (e.value, e.inserted_at, e.expires_at))
    }

    pub fn get(&self, key: &K) -> Option<&Entry<V>> {
        self.inner.get(key)
    }

    #[cfg(test)]
    pub fn remove(&mut self, key: &K) -> Option<Entry<V>> {
        self.expiration.retain(|_, keys| {
            keys.retain(|k| k != key);
            !keys.is_empty()
        });
        self.inner.remove(key)
    }

    pub fn poll_timeout(&self) -> Option<Instant> {
        self.expiration.keys().next().cloned()
    }

    pub fn clear(&mut self) {
        self.inner.clear();
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
}
