use core::fmt;
use std::{
    collections::VecDeque,
    task::{Context, Poll, Waker},
};

// Simple bounded queue for one-time events
#[derive(Debug, Clone)]
pub(crate) struct BoundedQueue<T> {
    queue: VecDeque<T>,
    limit: usize,
    waker: Option<Waker>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Error {
    Full,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Queue is full")
    }
}

impl<T> BoundedQueue<T> {
    pub(crate) fn with_capacity(cap: usize) -> BoundedQueue<T> {
        BoundedQueue {
            queue: VecDeque::with_capacity(cap),
            limit: cap,
            waker: None,
        }
    }

    pub(crate) fn poll(&mut self, cx: &Context) -> Poll<T> {
        if let Some(front) = self.queue.pop_front() {
            Poll::Ready(front)
        } else {
            if !self.waker.as_ref().is_some_and(|w| w.will_wake(cx.waker())) {
                self.waker = Some(cx.waker().clone());
            }

            Poll::Pending
        }
    }

    fn at_capacity(&self) -> bool {
        self.queue.len() == self.limit
    }

    pub(crate) fn push_back(&mut self, x: T) -> Result<(), Error> {
        if self.at_capacity() {
            return Err(Error::Full);
        }

        self.queue.push_back(x);

        if let Some(ref waker) = self.waker {
            waker.wake_by_ref();
        }

        Ok(())
    }
}
