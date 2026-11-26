//! `DeadlineMap` against a plain `HashMap` model.
//!
//! "Every mutable access marks the value; marked values are polled again before the cache is
//! read", so `poll_timeout` must always equal the earliest deadline of the current values.
#![allow(clippy::unwrap_used)]

use std::{
    collections::HashMap,
    time::{Duration, Instant},
};

use deadline_map::{DeadlineMap, PollTimeout};
use ephyra::gens;
use ephyra::prelude::*;

#[derive(Debug)]
struct Value(Option<Instant>);

impl PollTimeout for Value {
    fn poll_timeout(&mut self) -> Option<Instant> {
        self.0
    }
}

#[derive(Clone, Debug, PartialEq, ephyra::Arbitrary)]
enum Op {
    PollTimeout,
    Insert(
        #[ephyra(gen = gens::int(0u8..=7))] u8,
        #[ephyra(gen = gens::option(gens::int(0u8..=20)))] Option<u8>,
    ),
    GetOrInsert(
        #[ephyra(gen = gens::int(0u8..=7))] u8,
        #[ephyra(gen = gens::option(gens::int(0u8..=20)))] Option<u8>,
    ),
    GetMut(
        #[ephyra(gen = gens::int(0u8..=7))] u8,
        #[ephyra(gen = gens::option(gens::int(0u8..=20)))] Option<u8>,
    ),
    Remove(#[ephyra(gen = gens::int(0u8..=7))] u8),
    ExtractBelow(#[ephyra(gen = gens::int(0u8..=7))] u8),
    /// Sets the deadline of every value whose deadline is at most the first argument.
    FilterMut(
        #[ephyra(gen = gens::int(0u8..=20))] u8,
        #[ephyra(gen = gens::option(gens::int(0u8..=20)))] Option<u8>,
    ),
    /// Sets the deadline of every value `due_mut` hands out at the first argument.
    DueMut(
        #[ephyra(gen = gens::int(0u8..=20))] u8,
        #[ephyra(gen = gens::option(gens::int(0u8..=20)))] Option<u8>,
    ),
    Clear,
}

#[test]
fn poll_timeout_is_earliest_deadline() {
    let config = Config::default()
        .tests(20_000)
        .name("poll_timeout_is_earliest_deadline");
    let start = Instant::now();
    let at = move |s: Option<u8>| s.map(|s| start + Duration::from_secs(u64::from(s)));

    check(
        &config,
        gens::vec(ephyra::any::<Op>()).len(0..=40),
        move |ops| {
            let mut map = DeadlineMap::<u8, Value>::default();
            let mut model = HashMap::<u8, Option<Instant>>::new();

            for (i, op) in ops.iter().enumerate() {
                match op {
                    Op::PollTimeout => {}
                    Op::Insert(k, d) => {
                        assert_eq!(
                            map.insert(*k, Value(at(*d))).map(|v| v.0),
                            model.insert(*k, at(*d))
                        );
                    }
                    Op::GetOrInsert(k, d) => {
                        let v = map.get_or_insert(*k, Value(at(*d)));
                        let m = model.entry(*k).or_insert(at(*d));
                        assert_eq!(v.0, *m);
                        v.0 = at(d.map(|d| d / 2));
                        *m = v.0;
                    }
                    Op::GetMut(k, d) => {
                        if let Some(v) = map.get_mut(k) {
                            v.0 = at(*d);
                        }
                        if let Some(m) = model.get_mut(k) {
                            *m = at(*d);
                        }
                    }
                    Op::Remove(k) => {
                        assert_eq!(map.remove(k).map(|v| v.0), model.remove(k));
                    }
                    Op::ExtractBelow(k) => {
                        let mut got = map
                            .extract_if(|key, _| key < k)
                            .into_iter()
                            .map(|(k, _)| k)
                            .collect::<Vec<_>>();
                        got.sort();
                        let mut expected = model
                            .extract_if(|key, _| key < k)
                            .map(|(k, _)| k)
                            .collect::<Vec<_>>();
                        expected.sort();
                        assert_eq!(got, expected);
                    }
                    Op::FilterMut(t, d) => {
                        let threshold = at(Some(*t));
                        for (_, v) in map.filter_mut(|v| v.0.is_some_and(|x| Some(x) <= threshold))
                        {
                            v.0 = at(*d);
                        }
                        for m in model.values_mut() {
                            if m.is_some_and(|x| Some(x) <= threshold) {
                                *m = at(*d);
                            }
                        }
                    }
                    Op::DueMut(now, d) => {
                        let now = at(Some(*now)).unwrap();
                        let due = model
                            .iter()
                            .filter(|(_, m)| m.is_some_and(|m| m <= now))
                            .map(|(k, _)| *k)
                            .collect::<Vec<_>>();
                        let handed_out = map
                            .due_mut(now)
                            .map(|(k, v)| {
                                v.0 = at(*d);
                                k
                            })
                            .collect::<Vec<_>>();
                        for k in due {
                            assert!(
                                handed_out.contains(&k),
                                "step {i}: due value {k} was not handed out"
                            );
                        }
                        for k in handed_out {
                            model.insert(k, at(*d));
                        }
                    }
                    Op::Clear => {
                        map.clear();
                        model.clear();
                    }
                }

                assert_eq!(map.len(), model.len(), "step {i}");
                assert_eq!(
                    map.poll_timeout(),
                    model.values().filter_map(|d| *d).min(),
                    "step {i}: {op:?}"
                );
            }
        },
    )
    .assert_passed();
}
