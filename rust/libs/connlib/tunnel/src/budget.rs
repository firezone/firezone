use opentelemetry::{KeyValue, metrics::Histogram};
use std::{sync::OnceLock, task::Waker, time::Instant};

/// Tracks progress and iteration budget for an event-loop.
///
/// Call [`Budget::next`] in a `while let` loop to drive the event loop.
/// Each call yields a [`Tick`] guard; call [`Tick::want_continue`] to signal that work was done
/// and another iteration should follow.
/// When the budget is dropped, it wakes the waker if the budget was exhausted while still
/// making progress, so the runtime reschedules the task instead of suspending it indefinitely.
pub(crate) struct Budget<'a> {
    waker: &'a Waker,
    remaining: u32,
    ready: bool,
    started_at: Instant,
    name: &'static str,
}

pub(crate) struct Tick<'a>(&'a mut bool);

impl Tick<'_> {
    pub(crate) fn want_continue(&mut self) {
        *self.0 = true;
    }
}

impl<'a> Budget<'a> {
    pub(crate) fn new(waker: &'a Waker, budget: u32, name: &'static str) -> Self {
        Self {
            waker,
            remaining: budget,
            ready: true, // Treat the first iteration as "ready" so we always enter the loop once.
            started_at: Instant::now(),
            name,
        }
    }

    pub(crate) fn next(&mut self) -> Option<Tick<'_>> {
        if !self.ready || self.remaining == 0 {
            return None;
        }

        self.remaining -= 1;
        self.ready = false;

        Some(Tick(&mut self.ready))
    }
}

impl<'a> Drop for Budget<'a> {
    fn drop(&mut self) {
        let exhausted = self.remaining == 0;
        let elapsed_s = self.started_at.elapsed().as_secs_f64();

        poll_duration_histogram().record(
            elapsed_s,
            &[
                KeyValue::new("eventloop.exhausted", exhausted),
                KeyValue::new("eventloop.name", self.name),
            ],
        );

        if exhausted {
            self.waker.wake_by_ref();
        }
    }
}

fn poll_duration_histogram() -> &'static Histogram<f64> {
    static STORAGE: OnceLock<Histogram<f64>> = OnceLock::new();

    STORAGE.get_or_init(|| {
        opentelemetry::global::meter("connlib")
            .f64_histogram("eventloop.poll.duration")
            .with_description("Duration of a single event-loop poll.")
            .with_unit("s")
            .with_boundaries(vec![
                0.000_005, // 5µs
                0.000_010, // 10µs
                0.000_025, // 25µs
                0.000_050, // 50µs
                0.000_100, // 100µs
                0.000_250, // 250µs
                0.000_500, // 500µs
                0.001_000, // 1ms
                0.002_500, // 2.5ms
                0.005_000, // 5ms
                0.010_000, // 10ms
            ])
            .build()
    })
}

#[cfg(test)]
mod tests {
    use std::{
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        task::{RawWaker, RawWakerVTable},
    };

    use super::*;

    #[test]
    fn iterates_once_with_no_work_does_not_call_waker() {
        let (waker, wake_count) = counting_waker();
        let mut budget = Budget::new(&waker, 10, "test");

        let mut iterations = 0usize;
        while let Some(_tick) = budget.next() {
            iterations += 1;
        }

        assert_eq!(iterations, 1);
        assert_eq!(wake_count.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn continues_as_long_as_want_continue_is_called() {
        let (waker, wake_count) = counting_waker();
        let mut budget = Budget::new(&waker, 10, "test");

        let mut iterations = 0usize;
        while let Some(mut tick) = budget.next() {
            iterations += 1;
            if iterations < 3 {
                tick.want_continue();
            }
        }

        assert_eq!(iterations, 3);
        assert_eq!(wake_count.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn wakes_after_exhausting_budget() {
        let (waker, wake_count) = counting_waker();
        let mut budget = Budget::new(&waker, 10, "test");

        while let Some(mut tick) = budget.next() {
            tick.want_continue();
        }

        drop(budget);

        assert_eq!(wake_count.load(Ordering::SeqCst), 1);
    }

    fn counting_waker() -> (Waker, Arc<AtomicUsize>) {
        // Note: counting_waker is called multiple times per test in clone vtable, so Arc handles the ref-counting.
        let count = Arc::new(AtomicUsize::new(0));
        let waker = unsafe { Waker::from_raw(make_raw_waker(Arc::clone(&count))) };

        (waker, count)
    }

    const VTABLE: RawWakerVTable = RawWakerVTable::new(
        // clone
        |ptr| {
            let arc = unsafe { Arc::from_raw(ptr as *const AtomicUsize) };
            let cloned = Arc::clone(&arc);
            std::mem::forget(arc);
            make_raw_waker(cloned)
        },
        // wake (consumes the pointer)
        |ptr| {
            let arc = unsafe { Arc::from_raw(ptr as *const AtomicUsize) };
            arc.fetch_add(1, Ordering::SeqCst);
        },
        // wake_by_ref
        |ptr| {
            let arc = unsafe { Arc::from_raw(ptr as *const AtomicUsize) };
            arc.fetch_add(1, Ordering::SeqCst);
            std::mem::forget(arc);
        },
        // drop
        |ptr| {
            drop(unsafe { Arc::from_raw(ptr as *const AtomicUsize) });
        },
    );

    fn make_raw_waker(count: Arc<AtomicUsize>) -> RawWaker {
        let ptr = Arc::into_raw(count) as *const ();

        RawWaker::new(ptr, &VTABLE)
    }
}
