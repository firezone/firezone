use std::collections::VecDeque;

// Simple bounded queue for one-time events
#[derive(Debug, Clone)]
pub(crate) struct EventQueue<T> {
    queue: VecDeque<T>,
    limit: usize,
}

impl<T> EventQueue<T> {
    pub(crate) fn with_capacity(cap: usize) -> EventQueue<T> {
        EventQueue {
            queue: VecDeque::with_capacity(cap),
            limit: cap,
        }
    }

    pub(crate) fn pop_front(&mut self) -> Option<T> {
        self.queue.pop_front()
    }

    fn at_capacity(&self) -> bool {
        self.queue.len() == self.limit
    }

    pub(crate) fn push_back(&mut self, x: T) {
        if self.at_capacity() {
            self.queue.pop_front();
        }
        self.queue.push_back(x)
    }
}
