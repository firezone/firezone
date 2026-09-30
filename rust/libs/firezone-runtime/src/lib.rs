//! Single-threaded application runtime for clients and gateways.

#[cfg(not(target_vendor = "apple"))]
use anyhow::Context as _;
use anyhow::Result;
#[cfg(not(target_vendor = "apple"))]
use compio::compat::{RuntimeCompat, TokioAdapter};
use std::{future::Future, time::Duration};

pub struct Runtime {
    tasks: tokio::task::LocalSet,
    #[cfg(not(target_vendor = "apple"))]
    completion: RuntimeCompat<TokioAdapter>,
    tokio: tokio::runtime::Runtime,
}

impl Runtime {
    pub fn new() -> Result<Self> {
        if let Ok(core) = std::env::var("FIREZONE_PACKET_CORE") {
            pin_thread(core.parse()?)?;
        }
        let tokio = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        #[cfg(not(target_vendor = "apple"))]
        let completion = {
            let _guard = tokio.enter();
            let completion = RuntimeCompat::new(compio::runtime::Runtime::new()?)?;
            // Arm notification before a Tokio task can wake a Compio future.
            completion.poll_with(Some(Duration::ZERO));
            completion
        };
        Ok(Self {
            tasks: tokio::task::LocalSet::new(),
            #[cfg(not(target_vendor = "apple"))]
            completion,
            tokio,
        })
    }

    pub fn block_on<F: Future>(&self, future: F) -> F::Output {
        let future = self.tasks.run_until(future);
        #[cfg(not(target_vendor = "apple"))]
        let future = self.completion.execute(future);
        self.tokio.block_on(future)
    }

    pub fn enter(&self) -> tokio::runtime::EnterGuard<'_> {
        self.tokio.enter()
    }

    pub fn shutdown_timeout(self, timeout: Duration) {
        drop(self.tasks);
        #[cfg(not(target_vendor = "apple"))]
        drop(self.completion);
        self.tokio.shutdown_timeout(timeout);
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn pin_thread(core: usize) -> Result<()> {
    #[cfg(target_os = "linux")]
    let capacity = libc::CPU_SETSIZE as usize;
    #[cfg(target_os = "android")]
    let capacity = libc::CPU_SETSIZE;
    anyhow::ensure!(core < capacity, "CPU index exceeds affinity mask");
    let mut mask = unsafe { std::mem::zeroed::<libc::cpu_set_t>() };
    unsafe { libc::CPU_SET(core, &mut mask) };
    let result = unsafe { libc::sched_setaffinity(0, std::mem::size_of_val(&mask), &mask) };
    if result < 0 {
        return Err(std::io::Error::last_os_error()).context("Failed to pin completion thread");
    }
    Ok(())
}
#[cfg(windows)]
fn pin_thread(core: usize) -> Result<()> {
    use windows_sys::Win32::System::Threading::{GetCurrentThread, SetThreadAffinityMask};
    anyhow::ensure!(
        core < usize::BITS as usize,
        "CPU index exceeds processor group"
    );
    if unsafe { SetThreadAffinityMask(GetCurrentThread(), 1usize << core) } == 0 {
        return Err(std::io::Error::last_os_error()).context("Failed to pin completion thread");
    }
    Ok(())
}

#[cfg(target_vendor = "apple")]
fn pin_thread(_core: usize) -> Result<()> {
    anyhow::bail!("Pinning to a CPU core is unsupported on Apple platforms")
}

#[cfg(all(test, not(target_vendor = "apple")))]
#[expect(clippy::unwrap_used, reason = "Test assertions")]
mod tests {
    use super::*;
    use std::{cell::Cell, rc::Rc};

    #[test]
    fn local_tasks_keep_completion_io_on_the_owner_thread() {
        let runtime = Runtime::new().unwrap();
        let owner = std::thread::current().id();
        let completed = Rc::new(Cell::new(false));

        runtime.block_on(async {
            let task = tokio::task::spawn_local({
                let completed = completed.clone();
                async move {
                    let socket = compio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
                    let address = socket.local_addr().unwrap();
                    let compio::BufResult(result, _) = socket.send_to(vec![1, 2, 3], address).await;
                    assert_eq!(result.unwrap(), 3);
                    tokio::task::yield_now().await;
                    let compio::BufResult(result, packet) =
                        socket.recv(Vec::with_capacity(3)).await;
                    assert_eq!(result.unwrap(), 3);
                    assert_eq!(packet, [1, 2, 3]);
                    assert_eq!(std::thread::current().id(), owner);
                    completed.set(true);
                    socket.close().await.unwrap();
                }
            });
            tokio::time::timeout(Duration::from_secs(1), task)
                .await
                .unwrap()
                .unwrap();
        });

        assert!(completed.get());
        runtime.shutdown_timeout(Duration::from_secs(1));
    }
}
