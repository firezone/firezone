use crossbeam_queue::SegQueue;
use std::{cell::RefCell, collections::VecDeque, ops::Deref, rc::Rc, sync::Arc};

/// Selects a pool's reference counting and free-list storage.
pub trait Sharing: sealed::Sealed {
    type Shared<T>: Clone + Deref<Target = T>;
    type Queue<B>: Default;

    fn share<T>(value: T) -> Self::Shared<T>;
    fn pop<B>(queue: &Self::Queue<B>) -> Option<B>;
    fn push<B>(queue: &Self::Queue<B>, buffer: B);
}

/// Confines a pool and its buffers to one thread.
pub struct Local;

impl Sharing for Local {
    type Shared<T> = Rc<T>;
    type Queue<B> = RefCell<VecDeque<B>>;

    fn share<T>(value: T) -> Self::Shared<T> {
        Rc::new(value)
    }

    fn pop<B>(queue: &Self::Queue<B>) -> Option<B> {
        queue.borrow_mut().pop_front()
    }

    fn push<B>(queue: &Self::Queue<B>, buffer: B) {
        queue.borrow_mut().push_back(buffer);
    }
}

/// Allows a pool and its buffers to move between threads when their storage is `Send`.
pub struct ThreadSafe;

impl Sharing for ThreadSafe {
    type Shared<T> = Arc<T>;
    type Queue<B> = SegQueue<B>;

    fn share<T>(value: T) -> Self::Shared<T> {
        Arc::new(value)
    }

    fn pop<B>(queue: &Self::Queue<B>) -> Option<B> {
        queue.pop()
    }

    fn push<B>(queue: &Self::Queue<B>, buffer: B) {
        queue.push(buffer);
    }
}

mod sealed {
    pub trait Sealed {}
    impl Sealed for super::Local {}
    impl Sealed for super::ThreadSafe {}
}
