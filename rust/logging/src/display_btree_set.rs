use std::{collections::BTreeSet, fmt};

/// Adapter-struct to [`fmt::Display`] a [`BTreeSet`].
pub struct DisplayBTreeSet<'a, T>(pub &'a BTreeSet<T>);

impl<T> fmt::Display for DisplayBTreeSet<'_, T>
where
    T: fmt::Display,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut list = f.debug_list();

        for entry in self.0 {
            list.entry(&format_args!("{entry}"));
        }

        list.finish()
    }
}
