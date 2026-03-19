use std::iter;

use proptest::{prelude::*, sample::Selector};

/// Creates a [`Coin`] that when flipped, will yield [`Side::Head`] with the given probability.
pub(crate) fn head_biased(probability: u8) -> impl Strategy<Value = Coin> {
    assert!(probability <= 100);

    let samples = iter::empty()
        .chain((0..probability).map(|_| Side::Heads))
        .chain((probability..100).map(|_| Side::Tails))
        .collect::<Vec<_>>();

    assert_eq!(samples.len(), 100);

    let samples = Just(samples).prop_shuffle();
    let selector = any::<Selector>();

    (samples, selector).prop_map(|(samples, selector)| Coin { samples, selector })
}

#[derive(Debug)]
pub struct Coin {
    samples: Vec<Side>,
    selector: Selector,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Heads,
    Tails,
}

impl Coin {
    pub(crate) fn flip(&self) -> Side {
        self.selector.select(self.samples.iter().copied())
    }
}
