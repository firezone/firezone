use core::fmt;
use std::hash::Hash;
use std::{
    task::{ready, Context, Poll},
    time::Duration,
};

pub struct Stats {
    interval: tokio::time::Interval,
}

impl Stats {
    pub fn new(interval: Duration) -> Self {
        Self {
            interval: tokio::time::interval(interval),
        }
    }

    pub fn poll<TKind, TId>(
        &mut self,
        node: &snownet::Node<TKind, TId>,
        cx: &mut Context<'_>,
    ) -> Poll<()>
    where
        TId: fmt::Display + Copy + Eq + PartialEq + Hash,
    {
        ready!(self.interval.poll_tick(cx));

        let (node_stats, conn_stats) = node.stats();

        tracing::debug!(target: "connlib::stats", "{node_stats:?}");

        for (id, stats) in conn_stats {
            tracing::debug!(target: "connlib::stats", %id, "{stats:?}");
        }

        Poll::Ready(())
    }
}
