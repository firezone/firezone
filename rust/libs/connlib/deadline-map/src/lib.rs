//! A hash map that indexes its values by the deadline they report.

#![cfg_attr(test, allow(clippy::unwrap_used))]

#[cfg(test)]
mod tests;

use std::collections::{BTreeSet, HashMap, HashSet};
use std::hash::Hash;
use std::time::Instant;

use fast_random_state::FastRandomState;

/// A value that [`DeadlineMap`] indexes by its next deadline.
pub trait PollTimeout {
    fn poll_timeout(&mut self) -> Option<Instant>;
}

/// A hash map that indexes its values by their [`PollTimeout::poll_timeout`].
///
/// Every mutable access marks the value; marked values are re-indexed before the index is read.
pub struct DeadlineMap<K, V>
where
    V: PollTimeout,
{
    entries: HashMap<K, V, FastRandomState>,
    /// Entries handed out mutably since they were last indexed.
    touched: HashSet<K, FastRandomState>,
    deadline_by_key: HashMap<K, Instant, FastRandomState>,
    deadlines: BTreeSet<(Instant, K)>,
}

impl<K, V> Default for DeadlineMap<K, V>
where
    V: PollTimeout,
{
    fn default() -> Self {
        Self {
            entries: Default::default(),
            touched: Default::default(),
            deadline_by_key: Default::default(),
            deadlines: Default::default(),
        }
    }
}

impl<K, V> DeadlineMap<K, V>
where
    K: Eq + Hash + Ord + Copy,
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
        self.entries.get(key)
    }

    pub fn iter(&self) -> impl Iterator<Item = (K, &V)> {
        self.entries.iter().map(|(k, v)| (*k, v))
    }

    pub fn keys(&self) -> impl Iterator<Item = K> + '_ {
        self.entries.keys().copied()
    }

    pub fn values(&self) -> impl Iterator<Item = &V> {
        self.entries.values()
    }

    pub fn get_mut(&mut self, key: &K) -> Option<&mut V> {
        let value = self.entries.get_mut(key)?;
        self.touched.insert(*key);

        Some(value)
    }

    pub fn iter_mut(&mut self) -> impl Iterator<Item = (K, &mut V)> {
        self.filter_mut(|_| true)
    }

    /// Hands out and marks only the values matching `predicate`.
    pub fn filter_mut(
        &mut self,
        mut predicate: impl FnMut(&V) -> bool,
    ) -> impl Iterator<Item = (K, &mut V)> {
        let touched = &mut self.touched;

        self.entries.iter_mut().filter_map(move |(k, v)| {
            if !predicate(v) {
                return None;
            }

            touched.insert(*k);

            Some((*k, v))
        })
    }

    pub fn insert(&mut self, key: K, value: V) -> Option<V> {
        self.touched.insert(key);

        self.entries.insert(key, value)
    }

    pub fn get_or_insert(&mut self, key: K, value: V) -> &mut V {
        self.touched.insert(key);

        self.entries.entry(key).or_insert(value)
    }

    pub fn remove(&mut self, key: &K) -> Option<V> {
        self.unindex(key);

        self.entries.remove(key)
    }

    pub fn extract_if(&mut self, mut predicate: impl FnMut(&K, &V) -> bool) -> Vec<(K, V)> {
        let removed = self
            .entries
            .extract_if(|k, v| predicate(k, v))
            .collect::<Vec<_>>();

        for (k, _) in &removed {
            self.unindex(k);
        }

        removed
    }

    pub fn clear(&mut self) {
        self.entries.clear();
        self.touched.clear();
        self.deadline_by_key.clear();
        self.deadlines.clear();
    }

    /// Re-indexes the marked entries and passes each to `f`.
    pub fn reindex(&mut self, mut f: impl FnMut(K, &V)) {
        for key in self.touched.drain() {
            let Some(value) = self.entries.get_mut(&key) else {
                continue;
            };

            let new = value.poll_timeout();
            let old = match new {
                Some(deadline) => self.deadline_by_key.insert(key, deadline),
                None => self.deadline_by_key.remove(&key),
            };

            if old != new {
                if let Some(old) = old {
                    self.deadlines.remove(&(old, key));
                }
                if let Some(new) = new {
                    self.deadlines.insert((new, key));
                }
            }

            f(key, value);
        }
    }

    /// Re-indexes the marked entries and returns the earliest deadline.
    pub fn poll_timeout(&mut self) -> Option<Instant> {
        self.reindex(|_, _| {});

        let (deadline, _) = self.deadlines.first()?;

        Some(*deadline)
    }

    /// Calls `f` on the marked entries and then on those due at `now` in deadline order, leaving them marked.
    ///
    /// Returns the keys of the visited entries.
    pub fn handle_timeout(&mut self, now: Instant, mut f: impl FnMut(K, &mut V)) -> Vec<K> {
        let due = self
            .deadlines
            .iter()
            .take_while(|(deadline, _)| *deadline <= now)
            .map(|(_, key)| *key)
            .filter(|key| !self.touched.contains(key))
            .collect::<Vec<_>>();
        let keys = self.touched.drain().chain(due).collect::<Vec<_>>();

        keys.into_iter()
            .filter(|key| {
                let Some(value) = self.entries.get_mut(key) else {
                    return false;
                };

                f(*key, value);
                self.touched.insert(*key);

                true
            })
            .collect()
    }

    fn unindex(&mut self, key: &K) {
        self.touched.remove(key);

        if let Some(deadline) = self.deadline_by_key.remove(key) {
            self.deadlines.remove(&(deadline, *key));
        }
    }
}
