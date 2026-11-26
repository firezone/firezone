//! Building, serializing and parsing DNS responses with `dns-types`.
#![allow(clippy::unwrap_used)]

use ephyra::prelude::*;
use ephyra::{Gen, gens};

use dns_types::{DomainName, Query, RecordType, Response, ResponseBuilder, ResponseCode};

#[derive(Clone, Debug, PartialEq)]
struct Case {
    query_labels: Vec<u8>,
    edns: bool,
    names: Vec<Vec<u8>>,
    extra_total: u64,
    max_len: u16,
}

/// A name with one label per element, each label as long as the element says.
fn name(lengths: &[u8]) -> DomainName {
    lengths
        .iter()
        .map(|len| "a".repeat(usize::from(*len)))
        .collect::<Vec<_>>()
        .join(".")
        .parse()
        .unwrap()
}

fn labels() -> impl Gen<Value = Vec<u8>> {
    gens::vec(gens::int(1u8..=63)).len(1..=3)
}

fn cases() -> impl Gen<Value = Case> {
    (
        labels(),
        gens::bool(),
        gens::vec(labels()).len(0..=600),
        gens::int(0u64..=u64::MAX),
        gens::int(0u16..=u16::MAX),
    )
        .iso(
            |(query_labels, edns, names, extra_total, max_len)| Case {
                query_labels,
                edns,
                names,
                extra_total,
                max_len,
            },
            |c: &Case| {
                (
                    c.query_labels.clone(),
                    c.edns,
                    c.names.clone(),
                    c.extra_total,
                    c.max_len,
                )
            },
        )
}

/// What `handle_device_domain_browsed` in `tunnel-proto` does with a listing from the portal.
#[test]
fn device_listing_response_round_trips() {
    let config = Config::default()
        .tests(2_000)
        .name("device_listing_response_round_trips");

    check(&config, cases(), |case| {
        let query = Query::new(name(&case.query_labels), RecordType::PTR);
        let query = if case.edns { query.with_edns() } else { query };

        let total = case.names.len().saturating_add(case.extra_total as usize);
        let records = case
            .names
            .iter()
            .map(|n| (query.domain(), 30, dns_types::records::ptr(name(n))));
        let (builder, listed) = ResponseBuilder::for_query(&query, ResponseCode::NOERROR)
            .with_records_that_fit(records);
        ephyra::classify(listed < case.names.len(), "names did not fit");
        let note = (listed < total).then(|| format!("Lists {listed} of {total} names"));
        let response = builder.with_note(note.clone()).build();

        let bytes = response.clone().into_bytes(u16::MAX);
        let parsed = Response::parse(&bytes).unwrap();
        assert_eq!(parsed.records().count(), listed);
        assert!(!parsed.truncated());
        if case.edns {
            assert_eq!(parsed.note(), note.as_deref());
        }

        let truncated_bytes = response.into_bytes(case.max_len);
        let truncated = Response::parse(&truncated_bytes).unwrap();
        assert_eq!(
            truncated.truncated(),
            bytes.len() > usize::from(case.max_len)
        );
        assert_eq!(truncated.domain(), query.domain());
    })
    .assert_passed();
}
