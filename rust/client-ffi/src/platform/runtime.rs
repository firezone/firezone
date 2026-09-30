use anyhow::{Context as _, Result, anyhow};
use std::{sync::mpsc, thread, time::Duration};
use tokio::sync::oneshot;

pub struct RuntimeThread {
    shutdown: oneshot::Sender<()>,
    thread: thread::JoinHandle<()>,
}

impl RuntimeThread {
    pub fn start<T: Send + 'static>(
        setup: impl FnOnce() -> Result<(client_shared::Session, T)> + Send + 'static,
    ) -> Result<(Self, T)> {
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let thread = thread::Builder::new()
            .name("connlib".into())
            .spawn(move || {
                let runtime = match firezone_runtime::Runtime::new() {
                    Ok(runtime) => runtime,
                    Err(error) => {
                        let _ = ready_tx.send(Err(error));
                        return;
                    }
                };
                runtime.block_on(async {
                    let (session, value) = match setup() {
                        Ok(value) => value,
                        Err(error) => {
                            let _ = ready_tx.send(Err(error));
                            return;
                        }
                    };
                    if ready_tx.send(Ok(value)).is_ok() {
                        let _ = shutdown_rx.await;
                    }
                    session.stop();
                    let _ = tokio::time::timeout(Duration::from_secs(1), session.closed()).await;
                });
                runtime.shutdown_timeout(Duration::from_secs(1));
            })
            .context("Failed to start connlib thread")?;

        let value = match ready_rx
            .recv()
            .context("Connlib thread stopped during startup")
        {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => {
                let _ = thread.join();
                return Err(error);
            }
            Err(error) => {
                let _ = thread.join();
                return Err(error);
            }
        };
        Ok((
            Self {
                shutdown: shutdown_tx,
                thread,
            },
            value,
        ))
    }

    pub fn shutdown(self) -> Result<()> {
        let _ = self.shutdown.send(());
        self.thread
            .join()
            .map_err(|_| anyhow!("Connlib thread panicked"))?;
        Ok(())
    }
}
