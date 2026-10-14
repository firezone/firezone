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
