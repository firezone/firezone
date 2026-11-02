use std::{
    any::Any,
    future::Future,
    io,
    panic::AssertUnwindSafe,
    pin::Pin,
    task::{Context, Poll, ready},
};

use anyhow::{Result, anyhow};
use futures::{FutureExt as _, channel::oneshot};

/// Runs the future made by `make_future` on a new thread named `name`, on a single-threaded Tokio runtime of its own.
///
/// The thread is detached: it runs until the future completes, whether or not the returned [`ThreadOutput`] is polled.
pub fn spawn_thread<F, Fut>(name: &str, make_future: F) -> io::Result<ThreadOutput<Fut::Output>>
where
    F: FnOnce() -> Fut + Send + 'static,
    Fut: Future,
    Fut::Output: Send + 'static,
{
    let runtime = tokio::runtime::Builder::new_current_thread()
        .thread_name(name)
        .enable_all()
        .build()?;
    let (output_tx, output_rx) = oneshot::channel();

    std::thread::Builder::new()
        .name(name.to_owned())
        .spawn(move || {
            let output = std::panic::catch_unwind(AssertUnwindSafe(|| {
                runtime.block_on(async move { make_future().await })
            }))
            .map_err(panic_message);

            let _ = output_tx.send(output);
        })?;

    Ok(ThreadOutput {
        name: name.to_owned(),
        output_rx,
    })
}

/// Resolves to the output of the future run by [`spawn_thread`], or to an error if it panicked.
#[derive(Debug)]
pub struct ThreadOutput<T> {
    name: String,
    output_rx: oneshot::Receiver<Result<T, String>>,
}

impl<T> Future for ThreadOutput<T> {
    type Output = Result<T>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let output = match ready!(self.output_rx.poll_unpin(cx)) {
            Ok(Ok(output)) => Ok(output),
            Ok(Err(panic)) => Err(anyhow!("Thread `{}` panicked: {panic}", self.name)),
            Err(oneshot::Canceled) => Err(anyhow!("Thread `{}` exited without output", self.name)),
        };

        Poll::Ready(output)
    }
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
