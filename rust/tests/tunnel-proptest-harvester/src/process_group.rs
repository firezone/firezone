//! `Child` guard that SIGKILLs the whole process group on drop. Tokio's
//! `kill_on_drop` only targets cargo's own pid, which leaves the test
//! binary and rustc orphaned; `killpg` covers the subtree.

use std::ops::{Deref, DerefMut};

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio_stream::wrappers::LinesStream;
use tokio_stream::{Stream, StreamExt as _};

pub(crate) struct ProcessGroup(Child);

impl ProcessGroup {
    pub(crate) fn spawn(mut cmd: Command) -> std::io::Result<Self> {
        #[cfg(unix)]
        cmd.process_group(0);
        // Our `Drop` covers the whole group; skip tokio's per-pid kill.
        cmd.kill_on_drop(false);
        Ok(Self(cmd.spawn()?))
    }

    /// Panics if called twice: stdout/stderr can only be taken once.
    pub(crate) fn stdout_stderr(
        &mut self,
    ) -> impl Stream<Item = std::io::Result<String>> + Unpin + use<> {
        self.stdout().merge(self.stderr())
    }

    /// Panics if called twice: stdout can only be taken once.
    pub(crate) fn stdout(&mut self) -> impl Stream<Item = std::io::Result<String>> + Unpin + use<> {
        let stdout = self
            .0
            .stdout
            .take()
            .expect("child was spawned with Stdio::piped() for stdout");

        LinesStream::new(BufReader::new(stdout).lines())
    }

    /// Panics if called twice: stderr can only be taken once.
    pub(crate) fn stderr(&mut self) -> impl Stream<Item = std::io::Result<String>> + Unpin + use<> {
        let stderr = self
            .0
            .stderr
            .take()
            .expect("child was spawned with Stdio::piped() for stderr");

        LinesStream::new(BufReader::new(stderr).lines())
    }
}

impl Drop for ProcessGroup {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(pid) = self.0.id() {
            use nix::sys::signal::{Signal, killpg};
            use nix::unistd::Pid;
            let _ = killpg(Pid::from_raw(pid as i32), Signal::SIGKILL);
        }
    }
}

impl Deref for ProcessGroup {
    type Target = Child;
    fn deref(&self) -> &Child {
        &self.0
    }
}

impl DerefMut for ProcessGroup {
    fn deref_mut(&mut self) -> &mut Child {
        &mut self.0
    }
}
