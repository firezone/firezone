use std::{
    cell::RefCell,
    collections::VecDeque,
    rc::Rc,
    task::{Poll, Waker},
};

pub struct LocalQueue<T>(Rc<RefCell<(VecDeque<T>, Option<Waker>)>>);

impl<T> Clone for LocalQueue<T> {
    fn clone(&self) -> Self {
        Self(self.0.clone())
    }
}
impl<T> LocalQueue<T> {
    pub fn new() -> Self {
        Self(Rc::new(RefCell::new((VecDeque::new(), None))))
    }
    pub fn push(&self, item: T) {
        let mut queue = self.0.borrow_mut();
        queue.0.push_back(item);
        if let Some(waker) = queue.1.take() {
            waker.wake();
        }
    }
    pub async fn pop(&self) -> T {
        std::future::poll_fn(|cx| {
            let mut queue = self.0.borrow_mut();
            if let Some(item) = queue.0.pop_front() {
                return Poll::Ready(item);
            }
            queue.1 = Some(cx.waker().clone());
            Poll::Pending
        })
        .await
    }
}
