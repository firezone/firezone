use std::{
    any::Any,
    future::Future,
    io,
    panic::AssertUnwindSafe,
    pin::Pin,
    task::{Context, Poll, ready},
};

use anyhow::{Context as _, Result, anyhow};
use futures::{StreamExt as _, channel::mpsc};
use tokio::runtime::Runtime;

/// Builds a single-threaded runtime for the calling thread to drive with [`Runtime::block_on`].
///
/// Its tasks run on whichever thread calls `block_on`; it starts no thread of its own.
/// Only the threads it starts for blocking work (`spawn_blocking`, `tokio::fs`) are named `fz-blocking`.
pub fn current_thread() -> Result<Runtime> {
    build_runtime().context("Failed to create Tokio runtime")
}

/// Runs the future made by `make_future` on a new thread named `name`, on a runtime of its own from [`current_thread`].
///
/// The thread is detached: it runs until the future completes, whether or not the returned [`ThreadOutput`] is polled.
pub fn spawn_thread<F, Fut>(name: &str, make_future: F) -> ThreadOutput<Fut::Output>
where
    F: FnOnce() -> Fut + Send + 'static,
    Fut: Future,
    Fut::Output: Send + 'static,
{
    let (mut output_tx, output_rx) = mpsc::channel(1);
    let mut thread_output_tx = output_tx.clone();

    let spawn_result = std::thread::Builder::new()
        .name(name.to_owned())
        .spawn(move || {
            let output = build_runtime()
                .context("Failed to create Tokio runtime")
                .and_then(|runtime| {
                    std::panic::catch_unwind(AssertUnwindSafe(|| {
                        runtime.block_on(async move { make_future().await })
                    }))
                    .map_err(|panic| anyhow!("Panicked: {}", panic_message(panic)))
                });

            let _ = thread_output_tx.try_send(output);
        });

    if let Err(e) = spawn_result {
        let _ = output_tx.try_send(Err(anyhow::Error::new(e).context("Failed to spawn thread")));
    }
    drop(output_tx);

    ThreadOutput {
        name: name.to_owned(),
        output_rx,
    }
}

/// Resolves to the output of the future run by [`spawn_thread`], or to an error if the thread failed to create its runtime or panicked.
#[derive(Debug)]
#[must_use]
pub struct ThreadOutput<T> {
    name: String,
    output_rx: mpsc::Receiver<Result<T>>,
}

impl<T> Future for ThreadOutput<T> {
    type Output = Result<T>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let output = match ready!(self.output_rx.poll_next_unpin(cx)) {
            Some(output) => output.with_context(|| format!("Thread `{}` failed", self.name)),
            None => Err(anyhow!("Thread `{}` exited without output", self.name)),
        };

        Poll::Ready(output)
    }
}

fn build_runtime() -> io::Result<Runtime> {
    tokio::runtime::Builder::new_current_thread()
        .thread_name("fz-blocking")
        .enable_all()
        .build()
}

fn panic_message(panic: Box<dyn Any + Send>) -> String {
    if let Some(message) = panic.downcast_ref::<&str>() {
        return (*message).to_owned();
    }

    match panic.downcast::<String>() {
        Ok(message) => *message,
        Err(_) => "Box<dyn Any>".to_owned(),
    }
}
