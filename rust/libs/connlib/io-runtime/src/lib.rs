#![cfg_attr(test, allow(clippy::unwrap_used))]

//! Where connlib's data-plane IO tasks run.
//!
//! The TUN and UDP IO loops are Tokio tasks. `FIREZONE_IO_RUNTIME` selects, once per process,
//! which runtime polls them:
//!
//! - `dedicated` (the default): every [`task_runtime`] call spawns a thread of its own that runs a
//!   `current_thread` runtime, so the IO tasks land on four threads: `UDP IPv4`, `UDP IPv6`,
//!   `TUN send` and `TUN recv`.
//! - `io-thread`: one process-wide thread with a `current_thread` runtime hosts all IO tasks.
//! - `main`: the IO tasks run on the runtime that is current when [`task_runtime`] is called,
//!   i.e. next to the main event loop. [`main_runtime_builder`] makes that runtime
//!   `current_thread` so the event loop and the IO tasks share one OS thread.
//!
//! Any other value logs a warning and behaves like `dedicated`.

use std::env::VarError;
use std::io;
use std::sync::LazyLock;
use std::time::{Duration, Instant};
use tokio::runtime::{Builder, Handle};
use tokio::sync::oneshot;

const ENV_VAR: &str = "FIREZONE_IO_RUNTIME";

/// Returns the runtime that the IO tasks of the component `name` should run on.
///
/// # Panics
///
/// In `main` mode, panics when called outside a Tokio runtime context.
pub fn task_runtime(name: &str) -> io::Result<TaskRuntime> {
    let runtime = match *MODE {
        Mode::Dedicated => TaskRuntime::Dedicated(DedicatedRuntime::spawn(name)?),
        Mode::IoThread => {
            let io_thread = IO_THREAD
                .as_ref()
                .map_err(|e| io::Error::new(e.kind(), e.to_string()))?;

            TaskRuntime::Shared(io_thread.handle().clone())
        }
        Mode::Main => TaskRuntime::Shared(Handle::current()),
    };

    Ok(runtime)
}

/// Returns the builder for the runtime that hosts a process's main event loop.
///
/// In `main` mode this is a `current_thread` runtime so the IO tasks share the event loop's
/// thread; otherwise it is a multi-thread runtime with a single worker thread.
pub fn main_runtime_builder() -> Builder {
    match *MODE {
        Mode::Dedicated => single_worker_builder(),
        Mode::IoThread => single_worker_builder(),
        Mode::Main => Builder::new_current_thread(),
    }
}

/// Where the IO tasks of one component run.
pub enum TaskRuntime {
    /// A thread of its own that owns a `current_thread` runtime.
    Dedicated(DedicatedRuntime),
    /// An existing runtime shared with other tasks.
    Shared(Handle),
}

impl TaskRuntime {
    pub fn handle(&self) -> &Handle {
        match self {
            TaskRuntime::Dedicated(runtime) => runtime.handle(),
            TaskRuntime::Shared(handle) => handle,
        }
    }
}

/// A thread that owns a `current_thread` runtime for as long as this value lives.
///
/// Dropping it shuts the runtime down on its own thread, which drops all tasks spawned on it,
/// and waits a bounded time for the thread to exit.
pub struct DedicatedRuntime {
    handle: Handle,
    shutdown: Option<oneshot::Sender<()>>,
    thread: std::thread::JoinHandle<()>,
}

impl DedicatedRuntime {
    pub fn spawn(name: &str) -> io::Result<Self> {
        let (handle_tx, handle_rx) = std::sync::mpsc::channel();
        let (shutdown_tx, shutdown_rx) = oneshot::channel();

        let thread = std::thread::Builder::new()
            .name(name.to_owned())
            .spawn(move || {
                let runtime = match Builder::new_current_thread().enable_all().build() {
                    Ok(runtime) => runtime,
                    Err(e) => {
                        let _ = handle_tx.send(Err(e));
                        return;
                    }
                };

                let _ = handle_tx.send(Ok(runtime.handle().clone()));
                let _ = runtime.block_on(shutdown_rx);
            })?;

        let handle = handle_rx.recv().map_err(io::Error::other)??;

        Ok(Self {
            handle,
            shutdown: Some(shutdown_tx),
            thread,
        })
    }

    pub fn handle(&self) -> &Handle {
        &self.handle
    }
}

impl Drop for DedicatedRuntime {
    fn drop(&mut self) {
        const TIMEOUT: Duration = Duration::from_millis(500);

        let Some(shutdown) = self.shutdown.take() else {
            return;
        };
        let _ = shutdown.send(());

        let name = self.thread.thread().name().unwrap_or_default().to_owned();
        let start = Instant::now();

        while !self.thread.is_finished() {
            if start.elapsed() > TIMEOUT {
                tracing::debug!(%name, "Runtime thread did not stop within {TIMEOUT:?}");
                return;
            }

            std::thread::yield_now();
        }

        tracing::debug!(%name, duration = ?start.elapsed(), "Runtime thread stopped");
    }
}

#[derive(Debug, Clone, Copy)]
enum Mode {
    Dedicated,
    IoThread,
    Main,
}

static MODE: LazyLock<Mode> = LazyLock::new(|| {
    let mode = match std::env::var(ENV_VAR).as_deref() {
        Ok("dedicated") => Mode::Dedicated,
        Ok("io-thread") => Mode::IoThread,
        Ok("main") => Mode::Main,
        Ok(value) => {
            tracing::warn!(%value, "Unknown value for `{ENV_VAR}`; using default");

            Mode::Dedicated
        }
        Err(VarError::NotPresent) => Mode::Dedicated,
        Err(e @ VarError::NotUnicode(_)) => {
            tracing::warn!("Failed to read `{ENV_VAR}`: {e}; using default");

            Mode::Dedicated
        }
    };

    tracing::info!(?mode, "Selected IO runtime mode");

    mode
});

static IO_THREAD: LazyLock<io::Result<DedicatedRuntime>> =
    LazyLock::new(|| DedicatedRuntime::spawn("IO"));

fn single_worker_builder() -> Builder {
    let mut builder = Builder::new_multi_thread();
    builder.worker_threads(1);

    builder
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn dedicated_runtime_runs_tasks_on_its_own_thread() {
        let runtime = DedicatedRuntime::spawn("worker").unwrap();

        let thread_name = runtime
            .handle()
            .spawn(async { std::thread::current().name().map(ToOwned::to_owned) })
            .await
            .unwrap();

        assert_eq!(thread_name.as_deref(), Some("worker"));
    }

    #[tokio::test]
    async fn dropping_dedicated_runtime_cancels_its_tasks() {
        let runtime = DedicatedRuntime::spawn("worker").unwrap();
        let task = runtime.handle().spawn(std::future::pending::<()>());

        drop(runtime);

        assert!(task.is_finished());
        assert!(task.await.unwrap_err().is_cancelled());
    }

    #[tokio::test]
    async fn default_mode_is_dedicated() {
        let runtime = task_runtime("worker").unwrap();

        assert!(matches!(runtime, TaskRuntime::Dedicated(_)));
    }
}
