use connlib_shared::error::ConnlibError;
use connlib_shared::Callbacks;
use std::future::Future;

/// Spawns a task into the [`tokio`] runtime.
///
/// On error, [`Callbacks::on_error`] is invoked.
/// This also returns a [`tokio::task::AbortHandle`] which MAY be used to abort the task.
/// If you don't need it, you are free to drop it.
/// It won't terminate the task.
pub(crate) fn spawn_log(
    cb: &(impl Callbacks + 'static),
    f: impl Future<Output = Result<(), ConnlibError>> + Send + 'static,
) -> tokio::task::AbortHandle {
    let cb = cb.clone();

    tokio::spawn(async move {
        if let Err(e) = f.await {
            let _ = cb.on_error(&e);
        }
    })
    .abort_handle()
}
