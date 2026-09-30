use crossbeam_queue::SegQueue;
use std::{cell::RefCell, collections::VecDeque, ops::Deref, rc::Rc, sync::Arc};

/// Selects a pool's queue and reference counting.
///
/// [`Shared`] permits buffers to cross threads; [`Local`] keeps buffers on their owner thread.
pub trait Storage {
    type Handle<T>: Clone + Deref<Target = T>;
    type Queue<T>;
    fn handle<T>(value: T) -> Self::Handle<T>;
    fn queue<T>() -> Self::Queue<T>;
    fn pop<T>(queue: &Self::Queue<T>) -> Option<T>;
    fn push<T>(queue: &Self::Queue<T>, value: T);
}

pub struct Shared;

impl Storage for Shared {
    type Handle<T> = Arc<T>;
    type Queue<T> = SegQueue<T>;

    fn handle<T>(value: T) -> Self::Handle<T> {
        Arc::new(value)
    }

    fn queue<T>() -> Self::Queue<T> {
        SegQueue::new()
    }

    fn pop<T>(queue: &Self::Queue<T>) -> Option<T> {
        queue.pop()
    }

    fn push<T>(queue: &Self::Queue<T>, value: T) {
        queue.push(value);
    }
}

pub struct Local;

impl Storage for Local {
    type Handle<T> = Rc<T>;
    type Queue<T> = RefCell<VecDeque<T>>;

    fn handle<T>(value: T) -> Self::Handle<T> {
        Rc::new(value)
    }

    fn queue<T>() -> Self::Queue<T> {
        RefCell::new(VecDeque::new())
    }

    fn pop<T>(queue: &Self::Queue<T>) -> Option<T> {
        queue.borrow_mut().pop_front()
    }

    fn push<T>(queue: &Self::Queue<T>, value: T) {
        queue.borrow_mut().push_back(value);
    }
}
