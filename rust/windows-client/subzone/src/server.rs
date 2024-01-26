use anyhow::{bail, Context, Result};
use serde::{de::DeserializeOwned, Serialize};
use std::{
    ffi::c_void,
    marker::PhantomData,
    os::windows::io::{AsHandle, AsRawHandle},
    process::Stdio,
    time::Duration,
};
use tokio::{
    io::{AsyncWriteExt, WriteHalf},
    net::windows::named_pipe::{self, NamedPipeServer},
    process::{self, Child},
    sync::mpsc,
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

use crate::{read_deserialize, write_serialize, Error, ManagerMsgInternal, WorkerMsgInternal};

/// A named pipe server linked to a worker subprocess
pub struct Subprocess<M, W> {
    pub server: Server<M, W>,
    pub worker: SubcommandChild,
}

impl<M: Serialize, W: DeserializeOwned> Subprocess<M, W> {
    /// Returns a linked named pipe server and worker subprocess
    ///
    /// The process ID and cookie have already been checked for security
    /// when this function returns.
    pub async fn new(leak_guard: &mut LeakGuard, args: &[&str]) -> Result<Self> {
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

        let buf = read_deserialize(&mut server.pipe).await?;
        let buf = std::str::from_utf8(&buf)?;
        let WorkerMsgInternal::<W>::Cookie(echoed_cookie) = serde_json::from_str(buf)? else {
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
    pub(crate) pipe: named_pipe::NamedPipeServer,
}

impl UnconnectedServer {
    /// Requires a Tokio context
    pub(crate) fn new() -> Result<(Self, String)> {
        let id = super::random_pipe_id();
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
    pub(crate) async fn accept<M: Serialize, W: DeserializeOwned>(self) -> Result<Server<M, W>> {
        self.pipe.connect().await?;
        Server::new(self.pipe)
    }
}

/// A server that's connected to a client
///
/// Manual testing shows that if the corresponding Client's process crashes, Windows will
/// be nice and return errors for anything trying to read from the Server
pub struct Server<M, W> {
    client_pid: u32,
    pipe_writer: WriteHalf<NamedPipeServer>,
    /// Needed to make `next` cancel-safe
    read_rx: mpsc::Receiver<Vec<u8>>,
    /// Needed to make `next` cancel-safe
    _reader_task: tokio::task::JoinHandle<Result<()>>,
    _manager_msg: PhantomData<M>,
    _worker_msg: PhantomData<W>,
}

impl<M: Serialize, W: DeserializeOwned> Server<M, W> {
    #[tracing::instrument(skip_all)]
    fn new(pipe: named_pipe::NamedPipeServer) -> Result<Self> {
        let client_pid = get_client_pid(&pipe)?;
        let (mut pipe_reader, pipe_writer) = tokio::io::split(pipe);
        let (read_tx, read_rx) = mpsc::channel(1);
        let _reader_task = tokio::spawn(async move {
            loop {
                let msg = read_deserialize(&mut pipe_reader).await?;
                read_tx.send(msg).await?;
            }
        });

        Ok(Self {
            client_pid,
            pipe_writer,
            read_rx,
            _reader_task,
            _manager_msg: Default::default(),
            _worker_msg: Default::default(),
        })
    }

    /// Tells the pipe client to shutdown.
    ///
    /// Should be wrapped in a Tokio timeout in case the pipe client isn't responding.
    pub async fn close(mut self) -> Result<()> {
        write_serialize(&mut self.pipe_writer, &ManagerMsgInternal::<M>::Shutdown).await?;
        loop {
            // Pump out the read half until it errors
            match self.next().await {
                Ok(_) => {}
                Err(Error::Eof) => break,
                Err(error) => {
                    tracing::error!(?error, "Error while shutting down the named pipe");
                    break;
                }
            }
        }
        self.pipe_writer.shutdown().await?;
        Ok(())
    }

    pub fn client_pid(&self) -> u32 {
        self.client_pid
    }

    /// Receives a message from the client
    ///
    /// # Cancel safety
    ///
    /// This method is cancel-safe, internally it calls `tokio::sync::mpsc::Receiver::recv`
    pub async fn next(&mut self) -> Result<W, Error> {
        let buf = self.read_rx.recv().await.ok_or_else(|| Error::Eof)?;
        let buf = std::str::from_utf8(&buf)?;
        let msg = serde_json::from_str(buf)?;
        let WorkerMsgInternal::User(msg) = msg else {
            return Err(Error::Protocol);
        };
        Ok(msg)
    }

    pub async fn send(&mut self, msg: M) -> Result<(), Error> {
        write_serialize(&mut self.pipe_writer, &ManagerMsgInternal::User(msg)).await
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
pub struct SubcommandChild {
    pub(crate) process: Child,
}

///
#[derive(Debug, PartialEq)]
pub enum SubcommandExit {
    /// The process exited gracefully
    Success,
    /// The process didn't crash, but it returned a non-success exit code
    Failure,
    /// The process had to be killed
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
    pub(crate) fn wait_or_kill(&mut self) -> Result<SubcommandExit> {
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
///
/// This contains a Windows handle that always leaks. Try to create one LeakGuard
/// and use it throughout your whole main process.
pub struct LeakGuard {
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

    /// Registers a child process with the LeakGuard so that Windows will kill the child if the manager exits or crashes
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
