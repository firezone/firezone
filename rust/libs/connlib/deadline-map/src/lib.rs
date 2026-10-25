//! A hash map that caches the deadline each of its values reports.

#![cfg_attr(test, allow(clippy::unwrap_used))]

#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::hash::Hash;
use std::time::Instant;

use fast_random_state::FastRandomState;

/// A value whose next deadline [`DeadlineMap`] caches.
pub trait PollTimeout {
    fn poll_timeout(&mut self) -> Option<Instant>;
}

/// A hash map that caches the [`PollTimeout::poll_timeout`] of each value.
///
/// Every mutable access marks the value; marked values are polled again before the cache is read.
pub struct DeadlineMap<K, V>
where
    V: PollTimeout,
{
    entries: HashMap<K, Entry<V>, FastRandomState>,
}

struct Entry<V>
where
    V: PollTimeout,
{
    value: V,
    deadline: Option<Instant>,
    dirty: bool,
}

impl<V> Entry<V>
where
    V: PollTimeout,
{
    fn new(value: V) -> Self {
        Self {
            value,
            deadline: None,
            dirty: true,
        }
    }

    fn mark(&mut self) -> &mut V {
        self.dirty = true;

        &mut self.value
    }
}

impl<K, V> Default for DeadlineMap<K, V>
where
    V: PollTimeout,
{
    fn default() -> Self {
        Self {
            entries: Default::default(),
        }
    }
}

impl<K, V> DeadlineMap<K, V>
where
    K: Eq + Hash + Copy,
    V: PollTimeout,
{
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn contains_key(&self, key: &K) -> bool {
        self.entries.contains_key(key)
    }

    pub fn get(&self, key: &K) -> Option<&V> {
        self.entries.get(key).map(|e| &e.value)
    }

    pub fn iter(&self) -> impl Iterator<Item = (K, &V)> {
        self.entries.iter().map(|(k, e)| (*k, &e.value))
    }

    pub fn keys(&self) -> impl Iterator<Item = K> + '_ {
        self.entries.keys().copied()
    }

    pub fn values(&self) -> impl Iterator<Item = &V> {
        self.entries.values().map(|e| &e.value)
    }

    pub fn get_mut(&mut self, key: &K) -> Option<&mut V> {
        Some(self.entries.get_mut(key)?.mark())
    }

    pub fn iter_mut(&mut self) -> impl Iterator<Item = (K, &mut V)> {
        self.filter_mut(|_| true)
    }

    /// Hands out and marks only the values matching `predicate`.
    pub fn filter_mut(
        &mut self,
        mut predicate: impl FnMut(&V) -> bool,
    ) -> impl Iterator<Item = (K, &mut V)> {
        self.entries
            .iter_mut()
            .filter(move |(_, e)| predicate(&e.value))
            .map(|(k, e)| (*k, e.mark()))
    }

    pub fn insert(&mut self, key: K, value: V) -> Option<V> {
        self.entries.insert(key, Entry::new(value)).map(|e| e.value)
    }

    pub fn get_or_insert(&mut self, key: K, value: V) -> &mut V {
        self.entries.entry(key).or_insert(Entry::new(value)).mark()
    }

    pub fn remove(&mut self, key: &K) -> Option<V> {
        self.entries.remove(key).map(|e| e.value)
    }

    pub fn extract_if(&mut self, mut predicate: impl FnMut(&K, &V) -> bool) -> Vec<(K, V)> {
        self.entries
            .extract_if(|k, e| predicate(k, &e.value))
            .map(|(k, e)| (k, e.value))
            .collect()
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }

    /// Polls the marked entries again and passes each to `f`.
    pub fn reindex(&mut self, mut f: impl FnMut(K, &V)) {
        for (key, entry) in &mut self.entries {
            if !entry.dirty {
                continue;
            }

            entry.deadline = entry.value.poll_timeout();
            entry.dirty = false;

            f(*key, &entry.value);
        }
    }

    /// Polls the marked entries again and returns the earliest deadline.
    pub fn poll_timeout(&mut self) -> Option<Instant> {
        self.reindex(|_, _| {});

        self.entries.values().filter_map(|e| e.deadline).min()
    }

    /// Hands out and marks the marked entries and those due at `now`.
    pub fn due_mut(&mut self, now: Instant) -> impl Iterator<Item = (K, &mut V)> {
        self.entries
            .iter_mut()
            .filter(move |(_, e)| e.dirty || e.deadline.is_some_and(|d| d <= now))
            .map(|(k, e)| (*k, e.mark()))
    }
}
