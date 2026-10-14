use std::{hash::Hash, num::NonZeroUsize};

use fast_random_state::FastRandomState;
use lru::LruCache;

/// An LRU cache that remembers its most recent lookup in front of it.
///
/// Packets of a flow arrive in batches, so most lookups repeat the previous key and only cost a
/// comparison, while keys that interleave within a batch still hit the LRU.
pub(crate) struct Cache<K: Hash + Eq, V> {
    last: Last<K, V>,
    lru: LruCache<K, V, FastRandomState>,
}

impl<K: Hash + Eq, V> Cache<K, V> {
    pub(crate) fn new(capacity: NonZeroUsize) -> Self {
        Self {
            last: Last::default(),
            lru: LruCache::with_hasher(capacity, FastRandomState::default()),
        }
    }

    /// Forgets all cached values; call whenever the underlying data changes.
    pub(crate) fn clear(&mut self) {
        self.last.clear();
        self.lru.clear();
    }
}

impl<K, V> Cache<K, V>
where
    K: Hash + Eq + Clone,
    V: Clone,
{
    /// Returns the cached value for `key`, otherwise computes, caches and returns it.
    pub(crate) fn get_or_insert_with(&mut self, key: K, compute: impl FnOnce() -> V) -> &V {
        self.last
            .get_or_insert_with(key.clone(), || self.lru.get_or_insert(key, compute).clone())
    }
}

/// Remembers the result of the most recent lookup.
///
/// A lookup with a different key replaces the remembered entry.
pub(crate) struct Last<K, V> {
    entry: Option<(K, V)>,
}

impl<K, V> Default for Last<K, V> {
    fn default() -> Self {
        Self { entry: None }
    }
}

impl<K: PartialEq, V> Last<K, V> {
    /// Returns the remembered value if `key` matches, otherwise computes, remembers and returns it.
    ///
    /// A lookup with a different key replaces the remembered entry.
    pub(crate) fn get_or_insert_with(&mut self, key: K, compute: impl FnOnce() -> V) -> &V {
        if self.entry.as_ref().is_some_and(|(k, _)| *k != key) {
            self.entry = None;
        }

        &self.entry.get_or_insert_with(|| (key, compute())).1
    }

    /// Forgets the remembered value; call whenever the underlying data changes.
    pub(crate) fn clear(&mut self) {
        self.entry = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interleaved_keys_hit_the_lru() {
        let mut cache = Cache::new(NonZeroUsize::new(2).unwrap());

        assert_eq!(*cache.get_or_insert_with(1, || "a"), "a");
        assert_eq!(*cache.get_or_insert_with(2, || "b"), "b");
        assert_eq!(*cache.get_or_insert_with(1, || "c"), "a", "hit");

        cache.clear();
        assert_eq!(*cache.get_or_insert_with(1, || "d"), "d", "cleared");
    }

    #[test]
    fn remembers_the_last_lookup_until_cleared() {
        let mut last = Last::default();

        assert_eq!(*last.get_or_insert_with(1, || "a"), "a");
        assert_eq!(*last.get_or_insert_with(1, || "b"), "a", "hit");
        assert_eq!(*last.get_or_insert_with(2, || "c"), "c", "different key");
        assert_eq!(*last.get_or_insert_with(1, || "d"), "d", "replaced");

        last.clear();
        assert_eq!(*last.get_or_insert_with(1, || "e"), "e", "cleared");
    }
}
