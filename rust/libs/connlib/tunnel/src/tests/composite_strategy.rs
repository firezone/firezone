use proptest::strategy::{BoxedStrategy, Strategy, Union};
use std::fmt;

/// A custom [`Strategy`] that selects from a list of other, weighted strategies.
#[derive(Debug)]
pub struct CompositeStrategy<T>
where
    T: fmt::Debug,
{
    options: Vec<(u32, BoxedStrategy<T>)>,
}

impl<T> Default for CompositeStrategy<T>
where
    T: fmt::Debug,
{
    fn default() -> Self {
        Self {
            options: Vec::default(),
        }
    }
}

impl<T> CompositeStrategy<T>
where
    T: fmt::Debug,
{
    /// Adds a strategy to this [`CompositeStrategy`].
    pub fn with(mut self, prob: u32, strategy: impl Strategy<Value = T> + 'static) -> Self {
        self.options.push((prob, strategy.boxed()));

        self
    }

    /// Adds a strategy based on some input element if the element is not empty.
    pub fn with_if_not_empty<S, E>(
        self,
        prob: u32,
        element: E,
        make_strategy: impl Fn(E) -> S,
    ) -> Self
    where
        S: Strategy<Value = T> + 'static,
        E: IsEmpty,
    {
        if element.is_empty() {
            return self;
        }

        self.with(prob, make_strategy(element))
    }
}

pub trait IsEmpty {
    fn is_empty(&self) -> bool;
}

impl<T> IsEmpty for Vec<T> {
    fn is_empty(&self) -> bool {
        Vec::is_empty(self)
    }
}

impl<T> IsEmpty for Option<T> {
    fn is_empty(&self) -> bool {
        Option::is_none(self)
    }
}

impl<A, B> IsEmpty for (A, B)
where
    A: IsEmpty,
    B: IsEmpty,
{
    fn is_empty(&self) -> bool {
        self.0.is_empty() || self.1.is_empty()
    }
}

impl<A, B, C> IsEmpty for (A, B, C)
where
    A: IsEmpty,
    B: IsEmpty,
    C: IsEmpty,
{
    fn is_empty(&self) -> bool {
        self.0.is_empty() || self.1.is_empty() || self.2.is_empty()
    }
}

impl<T> Strategy for CompositeStrategy<T>
where
    T: fmt::Debug,
{
    type Tree = <Union<BoxedStrategy<T>> as Strategy>::Tree;

    type Value = T;

    fn new_tree(
        &self,
        runner: &mut proptest::prelude::prop::test_runner::TestRunner,
    ) -> proptest::prelude::prop::strategy::NewTree<Self> {
        Union::new_weighted(self.options.clone()).new_tree(runner)
    }
}
