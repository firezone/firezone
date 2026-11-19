//! Matches metric names against the patterns the portal hands out, in which `*` stands for any run of characters.

/// Returns whether `name` matches at least one of `patterns`.
pub fn is_allowed(name: &str, patterns: &[impl AsRef<str>]) -> bool {
    patterns
        .iter()
        .any(|pattern| matches(pattern.as_ref(), name))
}

/// Returns whether `name` matches `pattern`.
pub fn matches(pattern: &str, name: &str) -> bool {
    let mut parts = pattern.split('*');
    let first = parts.next().unwrap_or_default();

    let Some(mut rest) = name.strip_prefix(first) else {
        return false;
    };
    let Some(last) = parts.next_back() else {
        return rest.is_empty();
    };

    for part in parts {
        let Some(start) = rest.find(part) else {
            return false;
        };

        rest = &rest[start + part.len()..];
    }

    rest.ends_with(last)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_like_the_portal() {
        let allowed = ["connlib.*", "tunnel.error", "*.duration", "a*b*c"];

        for name in [
            "connlib.network.packets",
            "connlib.",
            "tunnel.error",
            "dns.duration",
            "abc",
            "aXbYc",
        ] {
            assert!(is_allowed(name, &allowed), "{name} should be allowed");
        }
        for name in ["tunnel.errors", "connlib", "duration", "acb", "abcd"] {
            assert!(!is_allowed(name, &allowed), "{name} should be rejected");
        }
        assert!(is_allowed("anything", &["*"]));
        assert!(!is_allowed("anything", &[] as &[&str]));
    }

    #[test]
    fn exact_pattern_matches_only_itself() {
        assert!(matches("connlib.dns.queries", "connlib.dns.queries"));
        assert!(!matches("connlib.dns.queries", "connlib.dns.queries.total"));
        assert!(!matches("connlib.dns.queries", "connlib.dns"));
    }

    #[test]
    fn suffix_after_wildcard_must_not_overlap_middle_part() {
        assert!(!matches("a*ab", "ab"));
        assert!(matches("a*ab", "aab"));
    }
}
