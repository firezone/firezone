//! Inter-process communication for the connlib subprocess
//!
//! To run the unit tests and multi-process tests, use
//! ```bash
//! cargo test --all-features -p firezone-windows-client && \
//! RUST_LOG=debug cargo run -p firezone-windows-client debug test-ipc
//! ```

use anyhow::{Context, Result};
use connlib_client_shared::ResourceDescription;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{
    ffi::c_void,
    marker::Unpin,
    os::windows::io::{AsHandle, AsRawHandle},
    process::{self, Child},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::windows::named_pipe,
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

#[derive(clap::Subcommand)]
pub enum Subcommand {
    Manager {
        pipe_id: String,
    },
    Worker {
        pipe_id: String,
    },

    LeakManager {
        #[arg(long, action = clap::ArgAction::Set)]
        enable_protection: bool,
        pipe_id: String,
    },
    LeakWorker {
        pipe_id: String,
    },
}

pub fn test_subcommand(cmd: Option<Subcommand>) -> Result<()> {
    tracing_subscriber::fmt::init();
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(async move {
        match cmd {
            None => {
                test_happy_path().await?;
                test_leak(true).await?;
                test_leak(false).await?;
                Ok(())
            }
            Some(Subcommand::Manager { pipe_id }) => test_manager_process(pipe_id).await,
            Some(Subcommand::Worker { pipe_id }) => test_worker_process(pipe_id).await,
            Some(Subcommand::LeakManager {
                enable_protection,
                pipe_id,
            }) => leak_manager(pipe_id, enable_protection),
            Some(Subcommand::LeakWorker { pipe_id }) => leak_worker(pipe_id).await,
        }
    })?;
    Ok(())
}

async fn test_happy_path() -> Result<()> {
    // Test normal IPC
    let id = random_pipe_id();

    let _manager = SubcommandChild::new(&["debug", "test-ipc", "manager", &id]);
    let _worker = SubcommandChild::new(&["debug", "test-ipc", "worker", &id]);

    tokio::time::sleep(Duration::from_secs(10)).await;
    Ok(())
}

async fn test_manager_process(pipe_id: String) -> Result<()> {
    let server = UnconnectedServer::new_with_id(&pipe_id)?;

    // TODO: The real manager would spawn the worker subprocess here, but
    // for this case, the test harness spawns it for us.

    let mut server = timeout(Duration::from_secs(5), server.accept()).await??;

    let start_time = std::time::Instant::now();
    assert_eq!(server.request(Request::Connect).await?, Response::Connected);
    assert_eq!(
        server.request(Request::AwaitCallback).await?,
        Response::CallbackOnUpdateResources(vec![])
    );
    assert_eq!(
        server.request(Request::Disconnect).await?,
        Response::Disconnected
    );

    let elapsed = start_time.elapsed();
    assert!(
        elapsed < std::time::Duration::from_millis(6),
        "{:?}",
        elapsed
    );
    tracing::info!(?elapsed, "made 3 IPC requests");

    Ok(())
}

async fn test_worker_process(pipe_id: String) -> Result<()> {
    let mut client = Client::new(&pipe_id)?;

    // Handle requests from the main process
    loop {
        let (req, responder) = client.next_request().await?;
        let resp = match &req {
            Request::AwaitCallback => Response::CallbackOnUpdateResources(vec![]),
            Request::Connect => Response::Connected,
            Request::Disconnect => Response::Disconnected,
        };
        responder.respond(resp).await?;

        if let Request::Disconnect = req {
            break;
        }
    }

    Ok(())
}

/// Top-level function to test whether the process leak protection works.
///
/// 1. Open a named pipe server
/// 2. Spawn a manager process, passing the pipe name to it
/// 3. The manager process spawns a worker process, passing the pipe name to it
/// 4. The manager process sets up leak protection on the worker process
/// 5. The worker process connects to our pipe server to confirm that it's up
/// 6. We SIGKILL the manager process
/// 7. Reading from the named pipe server should return an EOF since the worker process was killed by leak protection.
///
/// # Research
/// - [Stack Overflow example](https://stackoverflow.com/questions/53208/how-do-i-automatically-destroy-child-processes-in-windows)
/// - [Chromium example](https://source.chromium.org/chromium/chromium/src/+/main:base/process/launch_win.cc;l=421;drc=b7d560c40ceb5283dba3e3d305abd9e2e7e926cd)
/// - [MSDN docs](https://learn.microsoft.com/en-us/windows/win32/api/jobapi2/nf-jobapi2-assignprocesstojobobject)
/// - [windows-rs docs](https://microsoft.github.io/windows-docs-rs/doc/windows/Win32/System/JobObjects/fn.AssignProcessToJobObject.html)
async fn test_leak(enable_protection: bool) -> Result<()> {
    let (server, pipe_id) = UnconnectedServer::new()?;
    let args = [
        "debug",
        "test-ipc",
        "leak-manager",
        "--enable-protection",
        &enable_protection.to_string(),
        &pipe_id,
    ];
    let mut manager = SubcommandChild::new(&args)?;
    let mut server = timeout(Duration::from_secs(5), server.accept()).await??;

    {
        let server_handle = server.pipe.as_handle();
        let server_handle =
            HANDLE(unsafe { server_handle.as_raw_handle().offset_from(std::ptr::null()) });
        let mut client_pid = 0;
        unsafe { GetNamedPipeClientProcessId(server_handle, &mut client_pid) }?;
        tracing::info!("Actual pipe client PID = {client_pid}");
    }

    tracing::debug!("Harness accepted connection from Worker");

    // Send a few requests to make sure the worker is connected and good
    for _ in 0..3 {
        server.request(Request::AwaitCallback).await?;
    }

    tokio::time::sleep(std::time::Duration::from_secs(15)).await;

    manager.process.kill()?;
    tracing::debug!("Harness killed manager");

    // I can't think of a good way to synchronize with the worker process stopping,
    // so just give it 10 seconds for Windows to stop it.
    for _ in 0..10 {
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        if server.request(Request::AwaitCallback).await.is_err() {
            tracing::info!("confirmed worker stopped responding");
            break;
        }
    }

    if enable_protection {
        assert!(
            server.request(Request::AwaitCallback).await.is_err(),
            "worker shouldn't be able to respond here, it should have stopped when the manager stopped"
        );
        tracing::info!("enabling leak protection worked");
    } else {
        assert!(
            server.request(Request::AwaitCallback).await.is_ok(),
            "worker shouldn still respond here, this failure means the test is invalid"
        );
        tracing::info!("not enabling leak protection worked");
    }
    Ok(())
}

fn leak_manager(pipe_id: String, enable_protection: bool) -> Result<()> {
    let leak_guard = LeakGuard::new()?;

    let worker = SubcommandChild::new(&["debug", "test-ipc", "leak-worker", &pipe_id])?;
    tracing::info!("Expected worker PID = {}", worker.process.id());

    if enable_protection {
        leak_guard.add_process(&worker.process)?;
    }

    tracing::debug!("Manager set up leak protection, waiting for SIGKILL");
    loop {
        std::thread::park();
    }
}

async fn leak_worker(pipe_id: String) -> Result<()> {
    let mut client = Client::new(&pipe_id)?;
    tracing::debug!("Worker connected to named pipe");
    loop {
        let (_, responder) = client.next_request().await?;
        responder.respond(Response::CallbackTunnelReady).await?;
    }
}

/// Returns a random valid named pipe ID based on a UUIDv4
///
/// e.g. "\\.\pipe\dev.firezone.client\9508e87c-1c92-4630-bb20-839325d169bd"
///
/// Normally you don't need to call this directly. Tests may need it to inject
/// a known pipe ID into a process controlled by the test.
fn random_pipe_id() -> String {
    format!(r"\\.\pipe\dev.firezone.client\{}", uuid::Uuid::new_v4())
}

/// A server that accepts only one client
pub(crate) struct UnconnectedServer {
    pipe: named_pipe::NamedPipeServer,
}

impl UnconnectedServer {
    /// Requires a Tokio context
    pub fn new() -> anyhow::Result<(Self, String)> {
        let id = random_pipe_id();
        let this = Self::new_with_id(&id)?;
        Ok((this, id))
    }

    fn new_with_id(id: &str) -> anyhow::Result<Self> {
        let pipe = named_pipe::ServerOptions::new()
            .first_pipe_instance(true)
            .create(id)?;

        Ok(Self { pipe })
    }

    /// Accept an incoming connection
    ///
    /// This will wait forever if the client never shows up.
    /// Try pairing it with `tokio::time:timeout`
    pub async fn accept(self) -> anyhow::Result<Server> {
        self.pipe.connect().await?;
        Ok(Server { pipe: self.pipe })
    }
}

/// A server that's connected to a client
///
/// Manual testing shows that if the corresponding Client's process crashes, Windows will
/// be nice and return errors for anything trying to read from the Server
pub(crate) struct Server {
    pipe: named_pipe::NamedPipeServer,
}

/// A client that's connected to a server
///
/// Manual testing shows that if the corresponding Server's process crashes, Windows will
/// be nice and return errors for anything trying to read from the Client
pub(crate) struct Client {
    pipe: named_pipe::NamedPipeClient,
}

#[derive(Deserialize, Serialize)]
pub(crate) enum Request {
    AwaitCallback,
    Connect,
    Disconnect,
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum Response {
    CallbackOnUpdateResources(Vec<ResourceDescription>),
    CallbackTunnelReady,
    Connected,
    Disconnected,
}

#[must_use]
pub(crate) struct Responder<'a> {
    client: &'a mut Client,
}

impl Server {
    pub async fn request(&mut self, req: Request) -> Result<Response> {
        write_bincode(&mut self.pipe, &req)
            .await
            .context("couldn't send request")?;
        read_bincode(&mut self.pipe)
            .await
            .context("couldn't read response")
    }
}

impl Client {
    /// Creates a `Client`. Requires a Tokio context
    ///
    /// Doesn't block, will fail instantly if the server isn't ready
    pub fn new(server_id: &str) -> Result<Self> {
        let pipe = named_pipe::ClientOptions::new().open(server_id)?;
        Ok(Self { pipe })
    }

    pub async fn next_request(&mut self) -> Result<(Request, Responder)> {
        let req = read_bincode(&mut self.pipe).await?;
        let responder = Responder { client: self };
        Ok((req, responder))
    }
}

impl<'a> Responder<'a> {
    pub async fn respond(self, resp: Response) -> Result<()> {
        write_bincode(&mut self.client.pipe, &resp).await?;
        Ok(())
    }
}

/// Reads a message from an async reader, with a 32-bit little-endian length prefix
async fn read_bincode<R: AsyncRead + Unpin, T: DeserializeOwned>(reader: &mut R) -> Result<T> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf).await?;
    let len = u32::from_le_bytes(len_buf);
    let mut buf = vec![0u8; usize::try_from(len)?];
    reader.read_exact(&mut buf).await?;
    let msg = bincode::deserialize(&buf)?;
    Ok(msg)
}

/// Writes a message to an async writer, with a 32-bit little-endian length prefix
async fn write_bincode<W: AsyncWrite + Unpin, T: Serialize>(writer: &mut W, msg: &T) -> Result<()> {
    let buf = bincode::serialize(msg)?;
    let len = u32::try_from(buf.len())?.to_le_bytes();
    writer.write_all(&len).await?;
    writer.write_all(&buf).await?;
    Ok(())
}

/// `std::process::Child` but for a subcommand running from the same exe as
/// the current process.
///
/// Unlike `std::process::Child`, `Drop` tries to join the process, and kills it
/// if it can't.
struct SubcommandChild {
    process: Child,
}

impl SubcommandChild {
    /// Launches the current exe as a subprocess with new arguments
    ///
    /// # Parameters
    ///
    /// * `args` - e.g. `["debug", "test", "ipc-worker"]`
    pub fn new(args: &[&str]) -> Result<Self> {
        let mut process = process::Command::new(std::env::current_exe()?);
        for arg in args {
            process.arg(arg);
        }
        let process = process.spawn()?;
        Ok(SubcommandChild { process })
    }

    /// Joins the subprocess, returning an error if the process doesn't stop
    pub fn wait_or_kill(&mut self) -> Result<()> {
        if let Ok(Some(status)) = self.process.try_wait() {
            if status.success() {
                tracing::info!("process exited with success code");
            } else {
                tracing::warn!("process exited with non-success code");
            }
        } else {
            self.process.kill()?;
            tracing::error!("process was killed");
        }
        Ok(())
    }
}

impl Drop for SubcommandChild {
    fn drop(&mut self) {
        if let Err(error) = self.wait_or_kill() {
            tracing::error!(?error, "SubcommandChild could not be joined or killed");
        }
    }
}

/// Uses a Windows job object to kill child processes when the parent exits
pub(crate) struct LeakGuard {
    job_object: HANDLE,
}

impl LeakGuard {
    pub fn new() -> Result<Self> {
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

    pub fn add_process(&self, process: &std::process::Child) -> Result<()> {
        // Process IDs are not the same as handles, so get our handle to the process.
        let process_handle = process.as_handle();
        // SAFETY: The docs say this is UB since the null pointer doesn't belong to the same allocated object as the handle.
        // I couldn't get `OpenProcess` to work, and I don't have any other way to convert the process ID to a handle safely.
        // Since the handles aren't pointers per se, maybe it'll work?
        let process_handle =
            HANDLE(unsafe { process_handle.as_raw_handle().offset_from(std::ptr::null()) });
        // SAFETY: TODO
        unsafe { AssignProcessToJobObject(self.job_object, process_handle) }
            .context("AssignProcessToJobObject")?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::runtime::Runtime;

    /// Test just the happy path
    /// It's hard to simulate a process crash because:
    /// - If I Drop anything, Tokio will clean it up
    /// - If I `std::mem::forget` anything, the test process is still running, so Windows will not clean it up
    ///
    /// TODO: Simulate crashes of processes involved in IPC using our own test framework
    #[test]
    fn happy_path() -> anyhow::Result<()> {
        let rt = Runtime::new()?;
        rt.block_on(async move {
            // Pretend we're in the main process
            let (server, server_id) = UnconnectedServer::new()?;

            let worker_task = tokio::spawn(async move {
                // Pretend we're in a worker process
                let mut client = Client::new(&server_id)?;

                // Handle requests from the main process
                loop {
                    let (req, responder) = client.next_request().await?;
                    let resp = match &req {
                        Request::AwaitCallback => Response::CallbackOnUpdateResources(vec![]),
                        Request::Connect => Response::Connected,
                        Request::Disconnect => Response::Disconnected,
                    };
                    responder.respond(resp).await?;

                    if let Request::Disconnect = req {
                        break;
                    }
                }
                Ok::<_, anyhow::Error>(())
            });

            let mut server = server.accept().await?;

            let start_time = std::time::Instant::now();
            assert_eq!(server.request(Request::Connect).await?, Response::Connected);
            assert_eq!(
                server.request(Request::AwaitCallback).await?,
                Response::CallbackOnUpdateResources(vec![])
            );
            assert_eq!(
                server.request(Request::Disconnect).await?,
                Response::Disconnected
            );

            let elapsed = start_time.elapsed();
            assert!(
                elapsed < std::time::Duration::from_millis(6),
                "{:?}",
                elapsed
            );

            // Make sure the worker 'process' exited
            worker_task.await??;

            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }
}
