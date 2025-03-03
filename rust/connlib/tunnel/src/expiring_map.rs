use core::fmt;
use std::{collections::BTreeMap, mem, time::Instant};

/// A map that automatically removes entries after a given expiration time.
#[derive(Debug, Default)]
pub struct ExpiringMap<K, V> {
    inner: BTreeMap<K, V>,
    expiration: BTreeMap<Instant, Vec<K>>,
}

impl<K, V> ExpiringMap<K, V>
where
    K: Ord + Clone + fmt::Debug,
    V: fmt::Debug,
{
    pub fn insert(&mut self, key: K, value: V, expiration: Instant) -> Option<V> {
        let old_value = self.inner.insert(key.clone(), value);
        self.expiration.entry(expiration).or_default().push(key);

        old_value
    }

    pub fn get(&self, key: &K) -> Option<&V> {
        self.inner.get(key)
    }

    pub fn remove(&mut self, key: &K) -> Option<V> {
        self.expiration.retain(|_, keys| {
            keys.retain(|k| k != key);
            !keys.is_empty()
        });
        self.inner.remove(key)
    }

    pub fn poll_timeout(&self) -> Option<Instant> {
        self.expiration.keys().next().cloned()
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        let not_yet_expired = self.expiration.split_off(&now);

        for key in mem::replace(&mut self.expiration, not_yet_expired)
            .into_values()
            .flatten()
        {
            let Some(value) = self.inner.remove(&key) else {
                continue;
            };

            tracing::debug!(?key, ?value, "Entry expired");
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn poll_timeout_returns_next_expiration() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("key1", "value1", now + Duration::from_secs(1));
        map.insert("key2", "value2", now + Duration::from_secs(2));

        assert_eq!(map.poll_timeout(), Some(now + Duration::from_secs(1)));
    }

    #[test]
    fn handle_timeout_removes_expired_entries() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("key1", "value1", now + Duration::from_secs(1));
        map.insert("key2", "value2", now + Duration::from_secs(2));

        map.handle_timeout(now + Duration::from_millis(1001)); // Just after key1 expires

        assert_eq!(map.get(&"key1"), None);
        assert_eq!(map.get(&"key2"), Some(&"value2"));
    }

    #[test]
    fn removing_item_updates_expiration() {
        let mut map = ExpiringMap::default();
        let now = Instant::now();

        map.insert("key1", "value1", now + Duration::from_secs(1));
        map.insert("key2", "value2", now + Duration::from_secs(2));

        map.remove(&"key1");

        assert_eq!(map.poll_timeout(), Some(now + Duration::from_secs(2)));
    }
}
