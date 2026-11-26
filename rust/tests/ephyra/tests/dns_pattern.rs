//! DNS resource patterns, checked against a model of the documented semantics.
//!
//! <https://www.firezone.dev/kb/deploy/resources>: `**.example.com` matches `example.com` and
//! any subdomain, `*.example.com` matches `example.com` and its direct subdomains, `?` matches
//! a single character and wildcards may appear between labels. Matching is case-insensitive.
#![allow(clippy::unwrap_used)]

use std::cmp::Ordering;

use ephyra::prelude::*;
use ephyra::{Gen, gens};
use tunnel_proto::dns::{Pattern, is_subdomain};

const PATTERN_CHARS: [&str; 7] = ["a", "b", "A", "-", "*", "?", "**"];
/// A label on the wire can hold any byte, including a `.`.
const DOMAIN_CHARS: [&str; 6] = ["a", "b", "A", "-", ".", "*"];

fn labels(alphabet: usize, max_labels: usize) -> impl Gen<Value = Vec<Vec<usize>>> {
    gens::vec(gens::vec(gens::int(0..alphabet)).len(1..=3)).len(1..=max_labels)
}

fn render(tokens: &[Vec<usize>], alphabet: &[&str]) -> String {
    tokens
        .iter()
        .map(|label| match label.iter().find(|t| alphabet[**t] == "**") {
            Some(_) => "**".to_owned(),
            None => label.iter().map(|t| alphabet[*t]).collect::<String>(),
        })
        .collect::<Vec<_>>()
        .join(".")
}

fn label_matches(pattern: &[u8], label: &[u8]) -> bool {
    match pattern.split_first() {
        None => label.is_empty(),
        Some((b'*', rest)) => (0..=label.len()).any(|i| label_matches(rest, &label[i..])),
        Some((b'?', rest)) => !label.is_empty() && label_matches(rest, &label[1..]),
        Some((c, rest)) => label
            .split_first()
            .is_some_and(|(l, tail)| l.eq_ignore_ascii_case(c) && label_matches(rest, tail)),
    }
}

fn labels_match(pattern: &[&str], domain: &[&str]) -> bool {
    match pattern.split_first() {
        None => domain.is_empty(),
        Some((&"**", rest)) => {
            labels_match(rest, domain)
                || (!domain.is_empty() && labels_match(pattern, &domain[1..]))
        }
        Some((p, rest)) => domain.split_first().is_some_and(|(d, tail)| {
            label_matches(p.as_bytes(), d.as_bytes()) && labels_match(rest, tail)
        }),
    }
}

fn model_matches(pattern: &str, d: &[&str]) -> bool {
    let p = pattern.split('.').collect::<Vec<_>>();

    labels_match(&p, d) || (p[0] == "*" && labels_match(&p[1..], d))
}

#[test]
fn pattern_matches_like_documented() {
    let config = Config::default()
        .tests(20_000)
        .name("pattern_matches_like_documented");
    let generator = (
        labels(PATTERN_CHARS.len(), 4),
        labels(DOMAIN_CHARS.len(), 4),
    );

    check(&config, generator, |(p, d)| {
        let pattern = render(&p, &PATTERN_CHARS);
        let domain_labels = d
            .iter()
            .map(|l| l.iter().map(|t| DOMAIN_CHARS[*t]).collect::<String>())
            .collect::<Vec<_>>();
        let d = domain_labels.iter().map(String::as_str).collect::<Vec<_>>();
        let domain = domain_labels
            .iter()
            .map(|l| l.replace('.', "\\."))
            .collect::<Vec<_>>()
            .join(".");
        ephyra::assume!(Pattern::new(&pattern).is_ok());
        // The docs say nothing about a trailing `**`.
        ephyra::assume!(!pattern.ends_with("**"));

        let name = domain.parse::<dns_types::DomainName>().unwrap();

        let actual = is_subdomain(&name, &pattern);
        let expected = model_matches(&pattern, &d);
        if actual != expected {
            let apex_star = pattern.starts_with("*.")
                && pattern[2..].contains(['*', '?'])
                && labels_match(&pattern.split('.').skip(1).collect::<Vec<_>>(), &d);
            let dot_in_label = d.iter().any(|l| l.contains('.'));
            ephyra::signature(format!(
                "actual={actual} expected={expected} apex_star_with_wildcard_rest={apex_star} dot_in_label={dot_in_label}"
            ));
        }

        TestResult::check(actual == expected, format!("pattern {pattern} domain {domain}: actual {actual}, expected {expected}"))
    })
    .assert_passed();
}

#[test]
fn pattern_order_is_total_and_agrees_with_eq() {
    let config = Config::default()
        .tests(20_000)
        .name("pattern_order_is_total_and_agrees_with_eq");
    let generator = (
        labels(PATTERN_CHARS.len(), 3),
        labels(PATTERN_CHARS.len(), 3),
        labels(PATTERN_CHARS.len(), 3),
    );

    check(&config, generator, |(a, b, c)| {
        let parse = |t: &[Vec<usize>]| Pattern::new(&render(t, &PATTERN_CHARS)).ok();
        let (Some(a), Some(b), Some(c)) = (parse(&a), parse(&b), parse(&c)) else {
            return TestResult::Discard("invalid pattern".to_owned());
        };

        assert_eq!(a.cmp(&b) == Ordering::Equal, a == b, "{a} vs {b}");
        assert_eq!(a.cmp(&b), b.cmp(&a).reverse(), "{a} vs {b}");
        if a <= b && b <= c {
            assert!(a <= c, "{a} <= {b} <= {c}");
        }

        TestResult::Pass
    })
    .assert_passed();
}
