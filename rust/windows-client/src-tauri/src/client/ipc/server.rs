use crate::client::BUNDLE_ID;
use anyhow::{bail, Context, Result};
use std::{
    ffi::c_void,
    os::windows::io::{AsHandle, AsRawHandle},
    process::Stdio,
    time::Duration,
};
use tokio::{
    io::AsyncWriteExt,
    net::windows::named_pipe,
    process::{self, Child},
    sync::mpsc,
    task::JoinHandle,
    time::timeout,
};
use windows::Win32::{
    Foundation::HANDLE,
    System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectA, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    },
    System::Pipes::GetNamedPipeClientProcessId,
};

use super::{read_deserialize, write_serialize, Callback, Error, ManagerMsg, WorkerMsg};

/// A named pipe server linked to a worker subprocess
pub(crate) struct Subprocess {
    pub server: Server,
    pub worker: SubcommandChild,
}

impl Subprocess {
    /// Returns a linked named pipe server and worker subprocess
    ///
    /// The process ID and cookie have already been checked for security
    /// when this function returns.
    pub(crate) async fn new(leak_guard: &mut LeakGuard, args: &[&str]) -> Result<Self> {
        let (mut server, pipe_id) =
            UnconnectedServer::new().context("couldn't create UnconnectedServer")?;
        let mut process = process::Command::new(
            std::env::current_exe().context("couldn't get current exe name")?,
        );
        // Make the child's stdin piped so we can send it a security cookie.
        process.stdin(Stdio::piped());
        for arg in args {
            process.arg(arg);
        }
        process.arg(&pipe_id);
        let mut process = process.spawn().context("couldn't spawn subprocess")?;
        if let Err(error) = leak_guard.add_process(&process) {
            tracing::error!("couldn't add subprocess to leak guard, attempting to kill subprocess");
            process.kill().await.ok();
            return Err(error.context("couldn't add subprocess to leak guard"));
        }
        let child_pid = process
            .id()
            .ok_or_else(|| anyhow::anyhow!("child process should have an ID"))?;
        let mut worker = SubcommandChild { process };

        // Accept the connection
        server
            .pipe
            .connect()
            .await
            .context("expected a client connection")?;
        let client_pid = server.client_pid()?;

        // Make sure our child process connected to our pipe, and not some 3rd-party process
        if child_pid != client_pid {
            bail!("PID of child process and pipe client should match");
        }

        // Make sure the process on the other end of the pipe knows the cookie we went
        // to our child process' stdin
        let mut child_stdin = worker
            .process
            .stdin
            .take()
            .ok_or_else(|| anyhow::anyhow!("couldn't get stdin of subprocess"))?;
        let cookie = uuid::Uuid::new_v4().to_string();
        let line = format!("{}\n", cookie);
        tracing::trace!(?cookie, "Sending cookie");
        child_stdin
            .write_all(line.as_bytes())
            .await
            .context("couldn't write cookie to subprocess stdin")?;

        let WorkerMsg::Callback(Callback::Cookie(echoed_cookie)) =
            read_deserialize(&mut server.pipe)
                .await
                .context("couldn't read cookie back from subprocess")?
        else {
            bail!("didn't receive cookie from pipe client");
        };
        tracing::trace!(?echoed_cookie, "Got cookie back");
        if echoed_cookie != cookie {
            bail!("cookie received from pipe client should match the cookie we sent to our child process");
        }

        let server = Server::new(server.pipe)?;

        Ok(Self { server, worker })
    }
}

/// A server that accepts only one client
pub(crate) struct UnconnectedServer {
    pipe: named_pipe::NamedPipeServer,
}

impl UnconnectedServer {
    /// Requires a Tokio context
    pub(crate) fn new() -> Result<(Self, String)> {
        let id = random_pipe_id();
        let this = Self::new_with_id(&id)?;
        Ok((this, id))
    }

    fn client_pid(&self) -> Result<u32> {
        get_client_pid(&self.pipe)
    }

    fn new_with_id(id: &str) -> Result<Self> {
        let pipe = named_pipe::ServerOptions::new()
            .first_pipe_instance(true)
            .create(id)?;

        Ok(Self { pipe })
    }

    /// Accept an incoming connection
    ///
    /// This will wait forever if the client never shows up.
    /// Try pairing it with `tokio::time:timeout`
    pub(crate) async fn accept(self) -> Result<Server> {
        self.pipe.connect().await?;
        Server::new(self.pipe)
    }
}

/// Returns a random valid named pipe ID based on a UUIDv4
///
/// e.g. "\\.\pipe\dev.firezone.client\9508e87c-1c92-4630-bb20-839325d169bd"
///
/// Normally you don't need to call this directly. Tests may need it to inject
/// a known pipe ID into a process controlled by the test.
fn random_pipe_id() -> String {
    // TODO: DRY with `deep_link.rs`
    format!("\\\\.\\pipe\\{BUNDLE_ID}\\{}", uuid::Uuid::new_v4())
}

/// A server that's connected to a client
///
/// Manual testing shows that if the corresponding Client's process crashes, Windows will
/// be nice and return errors for anything trying to read from the Server
pub(crate) struct Server {
    pub cb_rx: mpsc::Receiver<Callback>,
    client_pid: u32,
    pipe_task: JoinHandle<Result<()>>,
    pub response_rx: mpsc::Receiver<ManagerMsg>,
    write_tx: mpsc::Sender<ServerInternalMsg>,
}

pub(crate) struct ServerReadHalf {
    pub cb_rx: mpsc::Receiver<Callback>,
    pub _response_rx: mpsc::Receiver<ManagerMsg>,
}

pub(crate) struct ServerWriteHalf {
    pipe_task: JoinHandle<Result<()>>,
    write_tx: mpsc::Sender<ServerInternalMsg>,
}

enum ServerInternalMsg {
    Msg(ManagerMsg),
    Shutdown,
}

impl ServerWriteHalf {
    pub async fn close(self) -> Result<()> {
        // Manager signals its pipe task that it will be shut down
        self.write_tx
            .send(ServerInternalMsg::Shutdown)
            .await
            .context("couldn't send ServerInternalMsg::Shutdown")?;
        let Self { pipe_task, .. } = self;
        pipe_task
            .await
            .context("async runtime error for ipc::Server::pipe_task")?
            .context("ipc::Server::pipe_task returned an error")?;
        Ok(())
    }

    pub async fn _send(&self, msg: ManagerMsg) -> Result<()> {
        self.write_tx.send(ServerInternalMsg::Msg(msg)).await?;
        Ok(())
    }
}

impl Server {
    #[tracing::instrument(skip_all)]
    fn new(pipe: named_pipe::NamedPipeServer) -> Result<Self> {
        let (cb_tx, cb_rx) = mpsc::channel(5);
        let (response_tx, response_rx) = mpsc::channel(5);
        let (write_tx, write_rx) = mpsc::channel(5);

        let client_pid = get_client_pid(&pipe)?;

        let pipe_task = tokio::task::spawn(async move {
            let output = Self::pipe_task(pipe, cb_tx, response_tx, write_rx).await;
            if let Err(error) = &output {
                tracing::error!(?error, "Server::pipe_task returned error");
            }
            output
        });

        Ok(Self {
            cb_rx,
            client_pid,
            pipe_task,
            response_rx,
            write_tx,
        })
    }

    pub(crate) async fn close(self) -> Result<()> {
        let (_read, write) = self.into_split();
        write.close().await
    }

    pub(crate) fn client_pid(&self) -> u32 {
        self.client_pid
    }

    /// Splits a `Server` into a read half and a write half, which can be used to read and write concurrently
    ///
    /// In the style of <https://docs.rs/tokio/latest/tokio/net/struct.TcpStream.html#method.into_split>
    pub(crate) fn into_split(self) -> (ServerReadHalf, ServerWriteHalf) {
        let Server {
            cb_rx,
            client_pid: _,
            pipe_task,
            response_rx: _response_rx,
            write_tx,
        } = self;

        (
            ServerReadHalf {
                cb_rx,
                _response_rx,
            },
            ServerWriteHalf {
                pipe_task,
                write_tx,
            },
        )
    }

    pub async fn send(&self, msg: ManagerMsg) -> Result<()> {
        self.write_tx.send(ServerInternalMsg::Msg(msg)).await?;
        Ok(())
    }

    /// Handles reading differently kinds of messages
    ///
    /// It is incidentally half-duplex, it can't read and write at the same time.
    #[tracing::instrument(skip_all)]
    async fn pipe_task(
        mut pipe: named_pipe::NamedPipeServer,
        cb_tx: mpsc::Sender<Callback>,
        response_tx: mpsc::Sender<ManagerMsg>,
        mut write_rx: mpsc::Receiver<ServerInternalMsg>,
    ) -> Result<()> {
        loop {
            // Note: Make sure these are all cancel-safe
            tokio::select! {
                // Thomas and ReactorScram assume this is cancel-safe
                ready = pipe.ready(tokio::io::Interest::READABLE) => {
                    tracing::trace!("waking up to read");
                    // Zero bytes just to see if any data is ready at all
                    let mut buf = [];
                    if ready?.is_readable() && pipe.try_read(&mut buf).is_ok() {
                        let msg = read_deserialize(&mut pipe).await?;
                        match msg {
                            WorkerMsg::Callback(cb) => cb_tx.send(cb).await?,
                            WorkerMsg::Response(resp) => response_tx.send(resp).await?,
                        }
                    }
                    else {
                        tracing::trace!("spurious wakeup");
                    }
                },
                // Cancel-safe per <https://docs.rs/tokio/latest/tokio/sync/mpsc/struct.Receiver.html#cancel-safety>
                msg = write_rx.recv() => {
                    let Some(msg) = msg else {
                        bail!("Server::write_rx closed suddenly");
                    };
                    let msg = match msg {
                        // Manager's pipe task stops reading
                        ServerInternalMsg::Shutdown => break,
                        ServerInternalMsg::Msg(msg) => msg,
                    };
                    write_serialize(&mut pipe, &msg).await?;
                },
            }
        }

        // Manager sends shut down message to worker
        write_serialize(&mut pipe, &ManagerMsg::Disconnect).await?;

        // Manager detects the pipe close and its pipe task ends
        // Discard any other callbacks or responses until we get the correct EOF error
        loop {
            let msg: Result<WorkerMsg, Error> = read_deserialize(&mut pipe).await;
            match msg {
                Ok(_) => {}
                Err(Error::Eof) => break,
                Err(e) => Err(e)?,
            }
        }

        pipe.shutdown().await?;
        tracing::debug!("Server::pipe_task exiting gracefully");
        Ok(())
    }
}

pub(crate) fn get_client_pid(pipe: &named_pipe::NamedPipeServer) -> Result<u32> {
    let handle = pipe.as_handle();
    // SAFETY: TODO
    let handle = HANDLE(unsafe { handle.as_raw_handle().offset_from(std::ptr::null()) });
    let mut pid = 0;
    // SAFETY: Not sure if this can be called from two threads at once?
    // But the pointer is valid at least.
    unsafe { GetNamedPipeClientProcessId(handle, &mut pid) }?;
    Ok(pid)
}

/// `std::process::Child` but for a subcommand running from the same exe as
/// the current process.
///
/// Unlike `std::process::Child`, `Drop` tries to join the process, and kills it
/// if it can't.
pub(crate) struct SubcommandChild {
    pub(crate) process: Child,
}

#[derive(Debug, PartialEq)]
pub(crate) enum SubcommandExit {
    Success,
    Failure,
    Killed,
}

impl SubcommandChild {
    /// Launches the current exe as a subprocess with new arguments
    ///
    /// # Parameters
    ///
    /// * `args` - e.g. `["debug", "test", "ipc-worker"]`
    pub fn new(args: &[&str]) -> Result<Self> {
        // Need this binding to avoid a "temporary freed while still in use" error
        let mut process = process::Command::new(std::env::current_exe()?);
        process
            // Make stdin a pipe so we can send the child a security cookie
            .stdin(Stdio::piped())
            // Best-effort attempt to kill the child when this handle drops
            // The Tokio docs say this is hard and we should just try to clean up
            // before dropping <https://docs.rs/tokio/latest/tokio/process/struct.Command.html#method.kill_on_drop>
            .kill_on_drop(true);
        for arg in args {
            process.arg(arg);
        }
        let process = process.spawn()?;
        Ok(SubcommandChild { process })
    }

    /// Joins the subprocess without blocking, returning an error if the process doesn't stop
    #[tracing::instrument(skip(self))]
    pub fn wait_or_kill(&mut self) -> Result<SubcommandExit> {
        if let Ok(Some(status)) = self.process.try_wait() {
            if status.success() {
                Ok(SubcommandExit::Success)
            } else {
                Ok(SubcommandExit::Failure)
            }
        } else {
            self.process.start_kill()?;
            Ok(SubcommandExit::Killed)
        }
    }

    /// Waits `dur` for process to exit gracefully, and then `dur` to kill process if needed
    pub async fn wait_then_kill(&mut self, dur: Duration) -> Result<SubcommandExit> {
        if let Ok(status) = timeout(dur, self.process.wait()).await {
            return if status?.success() {
                Ok(SubcommandExit::Success)
            } else {
                Ok(SubcommandExit::Failure)
            };
        }

        timeout(dur, self.process.kill()).await??;
        Ok(SubcommandExit::Killed)
    }
}

impl Drop for SubcommandChild {
    fn drop(&mut self) {
        match self.wait_or_kill() {
            Ok(SubcommandExit::Killed) => tracing::error!("SubcommandChild was killed inside Drop"),
            // Don't care - might have already been handled before Drop
            Ok(_) => {}
            Err(error) => tracing::error!(?error, "SubcommandChild could not be joined or killed"),
        }
    }
}

/// Uses a Windows job object to kill child processes when the parent exits
pub(crate) struct LeakGuard {
    // Technically this job object handle does leak
    job_object: HANDLE,
}

impl LeakGuard {
    pub fn new() -> Result<Self> {
        // SAFETY: TODO
        let job_object = unsafe { CreateJobObjectA(None, None) }?;

        let mut jeli = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        // SAFETY: Windows shouldn't hang on to `jeli`. I'm not sure why this is unsafe.
        unsafe {
            SetInformationJobObject(
                job_object,
                JobObjectExtendedLimitInformation,
                &jeli as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION as *const c_void,
                u32::try_from(std::mem::size_of_val(&jeli))?,
            )
        }?;

        Ok(Self { job_object })
    }

    pub fn add_process(&mut self, process: &Child) -> Result<()> {
        // Process IDs are not the same as handles, so get our handle to the process.
        let process_handle = process
            .raw_handle()
            .ok_or_else(|| anyhow::anyhow!("Child should have a handle"))?;
        // SAFETY: The docs say this is UB since the null pointer doesn't belong to the same allocated object as the handle.
        // I couldn't get `OpenProcess` to work, and I don't have any other way to convert the process ID to a handle safely.
        // Since the handles aren't pointers per se, maybe it'll work?
        let process_handle = HANDLE(unsafe { process_handle.offset_from(std::ptr::null()) });
        // SAFETY: TODO
        unsafe { AssignProcessToJobObject(self.job_object, process_handle) }
            .context("AssignProcessToJobObject")?;
        Ok(())
    }
}
