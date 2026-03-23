use super::*;
use std::{convert::Infallible, fmt, str::FromStr};

#[derive(Eq, Clone)]
pub struct Pattern {
    inner: glob::Pattern,
    original: String,
}

impl std::hash::Hash for Pattern {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.original.hash(state)
    }
}

impl fmt::Debug for Pattern {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Pattern").field(&self.original).finish()
    }
}

impl PartialEq for Pattern {
    fn eq(&self, other: &Self) -> bool {
        self.original == other.original
    }
}

impl fmt::Display for Pattern {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.original.fmt(f)
    }
}

impl PartialOrd for Pattern {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Pattern {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        // Iterate over characters in reverse order so that e.g. `*.example.com` and `subdomain.example.com` will compare the `example.com` suffix
        let mut self_rev = self.original.chars().rev();
        let mut other_rev = other.original.chars().rev();

        loop {
            let self_next = self_rev.next();
            let other_next = other_rev.next();

            match (self_next, other_next) {
                (Some(self_char), Some(other_char)) if self_char == other_char => {
                    continue;
                }
                // `*` > `?`
                (Some('*'), Some('?')) => break std::cmp::Ordering::Greater,
                (Some('?'), Some('*')) => break std::cmp::Ordering::Less,

                // Domains that only differ in wildcard come later
                (Some('*') | Some('?'), None | Some('.')) => break std::cmp::Ordering::Greater,
                (None | Some('.'), Some('*') | Some('?')) => break std::cmp::Ordering::Less,

                // `*` | `?` > non-wildcard
                (Some('*') | Some('?'), Some(_)) => break std::cmp::Ordering::Greater,
                (Some(_), Some('*') | Some('?')) => break std::cmp::Ordering::Less,

                // non-wildcard lexically
                (Some(self_char), Some(other_char)) => {
                    break self_char.cmp(&other_char).reverse(); // Reverse because we compare from right to left.
                }

                // Shorter domains come first
                (Some(_), None) => break std::cmp::Ordering::Greater,
                (None, Some(_)) => break std::cmp::Ordering::Less,

                (None, None) => break std::cmp::Ordering::Equal,
            }
        }
    }
}

impl Pattern {
    pub fn new(p: &str) -> Result<Self, glob::PatternError> {
        Ok(Self {
            inner: glob::Pattern::new(&p.replace('.', "/"))?,
            original: p.to_string(),
        })
    }

    /// Matches a [`Candidate`] against this [`Pattern`].
    ///
    /// Matching only requires a reference, thus allowing users to test a [`Candidate`] against multiple [`Pattern`]s.
    pub fn matches(&self, domain: &Candidate) -> bool {
        let domain = domain.0.as_str();

        if let Some(rem) = self.inner.as_str().strip_prefix("*/")
            && domain == rem
        {
            return true;
        }

        self.inner.matches_with(
            domain,
            glob::MatchOptions {
                case_sensitive: false,
                require_literal_separator: true,
                require_literal_leading_dot: false,
            },
        )
    }
}

/// A candidate for matching against a domain [`Pattern`].
///
/// Creates a type-safe contract that replaces `.` with `/` in the domain which is requires for pattern matching.
pub struct Candidate(String);

impl Candidate {
    pub fn from_domain(domain: &dns_types::DomainName) -> Self {
        Self(domain.to_string().replace('.', "/"))
    }
}

impl FromStr for Candidate {
    type Err = Infallible;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(Self(s.replace('.', "/")))
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    #[test]
    fn pattern_ordering() {
        let patterns = BTreeSet::from([
            Pattern::new("**.example.com").unwrap(),
            Pattern::new("bar.example.com").unwrap(),
            Pattern::new("foo.example.com").unwrap(),
            Pattern::new("example.com").unwrap(),
            Pattern::new("*ample.com").unwrap(),
            Pattern::new("*.bar.example.com").unwrap(),
            Pattern::new("?.example.com").unwrap(),
            Pattern::new("*.com").unwrap(),
            Pattern::new("*.example.com").unwrap(),
        ]);

        assert_eq!(
            Vec::from_iter(patterns),
            vec![
                Pattern::new("example.com").unwrap(), // Shorter domains first.
                Pattern::new("bar.example.com").unwrap(), // Lexical-ordering by default.
                Pattern::new("*.bar.example.com").unwrap(), // Lexically takes priority over specific match.
                Pattern::new("foo.example.com").unwrap(),   // Most specific next.
                Pattern::new("?.example.com").unwrap(),     // Single-wildcard second.
                Pattern::new("*.example.com").unwrap(),     // Star-wildcard third.
                Pattern::new("**.example.com").unwrap(),    // Double-star wildcard last.
                Pattern::new("*ample.com").unwrap(), // Specific match takes priority over wildcard.
                Pattern::new("*.com").unwrap(),      // Wildcards after all non-wildcards.
            ]
        )
    }
}
