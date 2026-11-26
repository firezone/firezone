//! Shrunk counterexamples found by the properties in this crate.
#![allow(clippy::unwrap_used)]

use tunnel_proto::dns::is_subdomain;

/// `*.example.com` matches `example.com`, and `us-east?.example.com` matches
/// `us-east1.example.com`, so `*.us-east?.example.com` should match `us-east1.example.com`.
#[test]
fn single_star_matches_apex_of_wildcard_pattern() {
    let domain = "us-east1.example.com".parse().unwrap();

    assert!(is_subdomain(&domain, "us-east?.example.com"));
    assert!(is_subdomain(&domain, "*.us-east?.example.com"));
}

#[test]
fn escaped_dot_is_not_a_label_boundary() {
    let domain = "evil\\.example.com"
        .parse::<dns_types::DomainName>()
        .unwrap();
    assert_eq!(domain.label_count(), 3);

    assert!(!is_subdomain(&domain, "*.example.com"));
}
