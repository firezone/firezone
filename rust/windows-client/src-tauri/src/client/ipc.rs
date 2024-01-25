//! Inter-process communication for the connlib subprocess on Windows
//!
//! To run the unit tests and multi-process tests, use
//! ```bash
//! cargo test --all-features -p firezone-windows-client && \
//! RUST_LOG=debug cargo run -p firezone-windows-client debug test-ipc
//! ```
//!
//! # Design
//!
//! The IPC module is specialized for Firezone, but it could be made generic by
//! replacing `WorkerMsg` and `ManagerMsg` with generics.
//!
//! `ManagerMsg::Disconnect` is used as an in-band shutdown signal. It disconnects
//! connlib and then gracefully shuts down the named pipe and worker process.
//!
//! It has these features:
//!
//! - Kill unresponsive worker if needed
//! - Automatically kill workers if the manager process exits
//! - The manager can receive callbacks concurrently with 0 or 1 in-flight requests to the worker
//! - Confirms that the child process connected to our named pipe and not some other process
//!
//! # Graceful shutdown
//!
//! For consistency, graceful shutdowns of a worker process are always initiated
//! by the manager process. If a worker process wants to shut down, it should ask
//! the manager to shut it down, and the manager will enter the shutdown flow.
//!
//! Always initiating from the manager means that killing an unresponsive worker process
//! is only an edge case of a normal shutdown.
//!
//! A graceful shutdown requires 3 steps :
//!
//! 1. Closing the named pipe on both sides
//! 1. Stopping the `pipe_task` on both sides
//! 1. Exiting the worker process
//!
//! Closing one side of the named pipe will cause the other side's read half to
//! return an error, so only one side can close gracefully.
//!
//! The shutdown flow is:
//!
//! 1. Manager decides to shut down worker
//! 1. Manager signals its pipe task that it will be shut down
//! 1. Manager's pipe task stops reading and waits
//! 1. Manager sends shut down message to worker
//! 1. Worker signals its pipe task to shut down
//! 1. Worker's pipe task closes its end of the pipe cleanly and joins
//! 1. The manager's pipe task detects the pipe close and joins
//! 1. The worker exits its process
//! 1. The manager joins the worker process
//!
//! Since this is all async, it can and should be wrapped with a `tokio::time::timeout`.

use crate::client::BUNDLE_ID;
use anyhow::{bail, Context};
use connlib_shared::messages::{
    ResourceDescription, ResourceDescriptionCidr, ResourceDescriptionDns, ResourceId,
};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{
    ffi::c_void,
    marker::Unpin,
    os::windows::io::{AsHandle, AsRawHandle},
    process::Stdio,
    str::FromStr,
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
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

#[derive(Debug, thiserror::Error)]
enum Error {
    /// Used to detected graceful named pipe closes
    #[error("EOF")]
    Eof,
    /// Any IO error except EOF
    #[error(transparent)]
    Io(std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error("Something went wrong while converting message length to u32 or usize")]
    MessageLength,
    #[error(transparent)]
    Utf8(#[from] std::string::FromUtf8Error),
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        if e.kind() == std::io::ErrorKind::UnexpectedEof {
            Self::Eof
        } else {
            Self::Io(e)
        }
    }
}

#[derive(clap::Subcommand)]
pub(crate) enum Subcommand {
    LeakManager {
        #[arg(long, action = clap::ArgAction::Set)]
        enable_protection: bool,
        pipe_id: String,
    },
    LeakWorker {
        pipe_id: String,
    },

    SecurityWorker {
        pipe_id: String,
    },
    ApiWorker {
        pipe_id: String,
    },
}

pub fn test_subcommand(cmd: Option<Subcommand>) -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(async move {
        match cmd {
            None => {
                test_api().await.context("test_api failed")?;
                tracing::info!("test_api passed");
                test_security().await.context("test_security failed")?;
                tracing::info!("test_security passed");
                test_leak(false).await.context("test_leak(false) failed")?;
                test_leak(true).await.context("test_leak(true) failed")?;
                tracing::info!("test_leak passed");
                tracing::info!("all tests passed");
                Ok(())
            }
            Some(Subcommand::LeakManager {
                enable_protection,
                pipe_id,
            }) => leak_manager(pipe_id, enable_protection),
            Some(Subcommand::LeakWorker { pipe_id }) => leak_worker(pipe_id).await,
            Some(Subcommand::SecurityWorker { pipe_id }) => security_worker(pipe_id).await,
            Some(Subcommand::ApiWorker { pipe_id }) => test_api_worker(pipe_id).await,
        }
    })?;
    Ok(())
}

#[tracing::instrument(skip_all)]
async fn test_api() -> anyhow::Result<()> {
    let start_time = Instant::now();

    let leak_guard = LeakGuard::new()?;
    let args = ["debug", "test-ipc", "api-worker"];
    let Subprocess {
        mut server,
        mut worker,
    } = timeout(Duration::from_secs(10), Subprocess::new(&leak_guard, &args)).await??;
    tracing::debug!("Manager got connection from worker");

    server.send(ManagerMsg::Connect).await?;
    let resp = server
        .response_rx
        .recv()
        .await
        .context("should have gotten a response to Connect")?;
    anyhow::ensure!(resp == ManagerMsg::Connect);

    let cb = server
        .cb_rx
        .recv()
        .await
        .context("should have gotten a TunnelReady callback")?;
    assert_eq!(cb, Callback::TunnelReady);

    let cb = server
        .cb_rx
        .recv()
        .await
        .context("should have gotten a OnUpdateResources callback")?;
    assert_eq!(cb, Callback::OnUpdateResources(sample_resources()));

    let elapsed = start_time.elapsed();
    anyhow::ensure!(
        elapsed < Duration::from_millis(100),
        "IPC took too long: {elapsed:?}"
    );

    let timer = Instant::now();
    server.close().await?;
    let elapsed = timer.elapsed();
    anyhow::ensure!(
        elapsed < Duration::from_millis(20),
        "Server took too long to close: {elapsed:?}"
    );

    assert_eq!(
        worker.wait_then_kill(Duration::from_secs(5)).await?,
        SubcommandExit::Success
    );

    Ok(())
}

#[tracing::instrument(skip_all)]
async fn test_api_worker(pipe_id: String) -> anyhow::Result<()> {
    let mut client = client(&pipe_id).await?;

    client
        .send(WorkerMsg::Callback(Callback::TunnelReady))
        .await?;

    client
        .send(WorkerMsg::Callback(Callback::OnUpdateResources(
            sample_resources(),
        )))
        .await?;

    tracing::trace!("Worker connected to named pipe");
    loop {
        let Some(req) = client.request_rx.recv().await else {
            anyhow::bail!("named pipe closed unexpectedly");
        };
        tracing::trace!(?req, "worker got request");
        client.send(WorkerMsg::Response(req.clone())).await?;
        tracing::trace!(?req, "worker replied");
        if let ManagerMsg::Disconnect = req {
            break;
        }
    }

    let timer = Instant::now();
    client.close().await?;
    let elapsed = timer.elapsed();
    anyhow::ensure!(
        elapsed < Duration::from_millis(5),
        "Client took too long to close: {elapsed:?}"
    );
    Ok(())
}

#[tracing::instrument(skip_all)]
async fn test_security() -> anyhow::Result<()> {
    let start_time = Instant::now();

    let leak_guard = LeakGuard::new()?;
    let (server, pipe_id) = UnconnectedServer::new()?;
    let args = ["debug", "test-ipc", "security-worker", &pipe_id];
    let mut worker = SubcommandChild::new(&args)?;
    leak_guard.add_process(&worker.process)?;
    let mut server = timeout(Duration::from_secs(5), server.accept()).await??;

    let client_pid = server.client_pid;
    let child_pid = worker.process.id().unwrap();
    assert_eq!(child_pid, client_pid);

    let mut child_stdin = worker
        .process
        .stdin
        .take()
        .ok_or_else(|| anyhow::anyhow!("couldn't get stdin of child process"))?;
    let cookie = uuid::Uuid::new_v4().to_string();
    let line = format!("{}\n", cookie);
    child_stdin.write_all(line.as_bytes()).await?;

    let Callback::Cookie(echoed_cookie) = server
        .cb_rx
        .recv()
        .await
        .context("should have gotten the cookie back")?
    else {
        bail!("callback should have been a cookie");
    };
    assert_eq!(echoed_cookie, cookie);

    server.close().await?;

    let elapsed = start_time.elapsed();
    assert!(elapsed < Duration::from_millis(200), "{:?}", elapsed);

    assert_eq!(
        worker.wait_then_kill(Duration::from_secs(5)).await?,
        SubcommandExit::Success
    );

    Ok(())
}

#[tracing::instrument(skip_all)]
async fn security_worker(pipe_id: String) -> anyhow::Result<()> {
    let mut client = Client::new(&pipe_id)?;
    let mut cookie = String::new();
    std::io::stdin().read_line(&mut cookie)?;
    let cookie = WorkerMsg::Callback(Callback::Cookie(cookie.trim().to_string()));
    client.send(cookie).await?;
    tracing::debug!("Worker connected to named pipe");
    loop {
        let Some(req) = client.request_rx.recv().await else {
            break;
        };
        client.send(WorkerMsg::Response(req.clone())).await?;
        if let ManagerMsg::Disconnect = req {
            break;
        }
    }
    client.close().await?;
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
#[tracing::instrument]
async fn test_leak(enable_protection: bool) -> anyhow::Result<()> {
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

    tracing::debug!("Actual pipe client PID = {}", server.client_pid);
    tracing::debug!("Harness accepted connection from Worker");

    // Send a few requests to make sure the worker is connected and good
    for _ in 0..3 {
        server.send(ManagerMsg::Connect).await?;
        server
            .response_rx
            .recv()
            .await
            .context("should have gotten a response to Connect")?;
    }

    timeout(Duration::from_secs(5), manager.process.kill()).await??;
    tracing::debug!("Harness killed manager");

    // I can't think of a good way to synchronize with the worker process stopping,
    // so just give it 10 seconds for Windows to stop it.
    for _ in 0..5 {
        if server.send(ManagerMsg::Connect).await.is_err() {
            tracing::info!("confirmed worker stopped responding");
            break;
        }
        if server.response_rx.recv().await.is_none() {
            tracing::info!("confirmed worker stopped responding");
            break;
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }

    if enable_protection {
        assert!(
            server.send(ManagerMsg::Connect).await.is_err(),
            "worker shouldn't be able to respond here, it should have stopped when the manager stopped"
        );
        assert!(
            server.response_rx.recv().await.is_none(),
            "worker shouldn't be able to respond here, it should have stopped when the manager stopped"
        );
        tracing::info!("enabling leak protection worked");
    } else {
        assert!(
            server.send(ManagerMsg::Connect).await.is_ok(),
            "worker should still respond here, this failure means the test is invalid"
        );
        assert!(
            server.response_rx.recv().await.is_some(),
            "worker should still respond here, this failure means the test is invalid"
        );
        tracing::info!("not enabling leak protection worked");
    }
    Ok(())
}

#[tracing::instrument]
fn leak_manager(pipe_id: String, enable_protection: bool) -> anyhow::Result<()> {
    let leak_guard = LeakGuard::new()?;

    let worker = SubcommandChild::new(&["debug", "test-ipc", "leak-worker", &pipe_id])?;
    tracing::debug!("Expected worker PID = {}", worker.process.id().unwrap());

    if enable_protection {
        leak_guard.add_process(&worker.process)?;
    }

    tracing::debug!("Manager set up leak protection, waiting for SIGKILL");
    loop {
        std::thread::park();
    }
}

#[tracing::instrument(skip_all)]
async fn leak_worker(pipe_id: String) -> anyhow::Result<()> {
    let mut client = Client::new(&pipe_id)?;
    tracing::debug!("Worker connected to named pipe");
    loop {
        let Some(req) = client.request_rx.recv().await else {
            anyhow::bail!("named pipe closed unexpectedly");
        };
        client.send(WorkerMsg::Response(req.clone())).await?;
        if let ManagerMsg::Disconnect = req {
            break;
        }
    }
    client.close().await?;
    Ok(())
}

fn sample_resources() -> Vec<ResourceDescription> {
    vec![
        ResourceDescription::Cidr(ResourceDescriptionCidr {
            id: ResourceId::from_str("2efe9c25-bd92-49a0-99d7-8b92da014dd5").unwrap(),
            name: "Cloudflare DNS".to_string(),
            address: ip_network::IpNetwork::from_str("1.1.1.1/32").unwrap(),
        }),
        ResourceDescription::Dns(ResourceDescriptionDns {
            id: ResourceId::from_str("613eaf56-6efa-45e5-88aa-ea4ad64d8c18").unwrap(),
            name: "Example".to_string(),
            address: "*.example.com".to_string(),
        }),
    ]
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
    pub(crate) async fn new(leak_guard: &LeakGuard, args: &[&str]) -> anyhow::Result<Self> {
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
        let client_pid = Server::client_pid(&server.pipe)?;

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

        let WorkerMsg::Callback(Callback::Cookie(echoed_cookie)) = Server::read(&mut server.pipe)
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

/// Returns a named pipe client for use in a worker subprocess
///
/// The security cookie has already been read from stdin and echoed to the pipe server.
pub(crate) async fn client(pipe_id: &str) -> anyhow::Result<Client> {
    let client = Client::new(pipe_id)?;
    let mut cookie = String::new();
    std::io::stdin().read_line(&mut cookie)?;
    let cookie = WorkerMsg::Callback(Callback::Cookie(cookie.trim().to_string()));
    client.send(cookie).await?;
    Ok(client)
}

/// A server that accepts only one client
struct UnconnectedServer {
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
        Server::new(self.pipe)
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum ManagerMsg {
    Connect,
    Disconnect,
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum WorkerMsg {
    /// A message that is not in response to any manager request
    ///
    /// Typically a wrapped connlib callback
    Callback(Callback),
    /// Response to a manager-initiated request to connlib (e.g. connect, disconnect)
    Response(ManagerMsg), // All ManagerMsg variants happen to be requests
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub(crate) enum Callback {
    /// Cookie for named pipe security
    Cookie(String),
    DisconnectedTokenExpired,
    /// Connlib disconnected and we should gracefully join the worker process
    OnDisconnect,
    OnUpdateResources(Vec<ResourceDescription>),
    TunnelReady,
}

/// A server that's connected to a client
///
/// Manual testing shows that if the corresponding Client's process crashes, Windows will
/// be nice and return errors for anything trying to read from the Server
pub(crate) struct Server {
    pub cb_rx: mpsc::Receiver<Callback>,
    client_pid: u32,
    pipe_task: JoinHandle<anyhow::Result<()>>,
    pub response_rx: mpsc::Receiver<ManagerMsg>,
    write_tx: mpsc::Sender<ServerInternalMsg>,
}

pub(crate) struct ServerReadHalf {
    pub cb_rx: mpsc::Receiver<Callback>,
    pub _response_rx: mpsc::Receiver<ManagerMsg>,
}

pub(crate) struct ServerWriteHalf {
    pipe_task: JoinHandle<anyhow::Result<()>>,
    write_tx: mpsc::Sender<ServerInternalMsg>,
}

enum ServerInternalMsg {
    Msg(ManagerMsg),
    Shutdown,
}

impl ServerWriteHalf {
    pub async fn close(self) -> anyhow::Result<()> {
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

    pub async fn _send(&self, msg: ManagerMsg) -> anyhow::Result<()> {
        self.write_tx.send(ServerInternalMsg::Msg(msg)).await?;
        Ok(())
    }
}

impl Server {
    #[tracing::instrument(skip_all)]
    fn new(pipe: named_pipe::NamedPipeServer) -> anyhow::Result<Self> {
        let (cb_tx, cb_rx) = mpsc::channel(5);
        let (response_tx, response_rx) = mpsc::channel(5);
        let (write_tx, write_rx) = mpsc::channel(5);

        let client_pid = Self::client_pid(&pipe)?;

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

    pub async fn close(self) -> anyhow::Result<()> {
        let (_read, write) = self.into_split();
        write.close().await
    }

    /// Splits a `Server` into a read half and a write half, which can be used to read and write concurrently
    ///
    /// In the style of <https://docs.rs/tokio/latest/tokio/net/struct.TcpStream.html#method.into_split>
    pub fn into_split(self) -> (ServerReadHalf, ServerWriteHalf) {
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

    pub async fn send(&self, msg: ManagerMsg) -> anyhow::Result<()> {
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
    ) -> anyhow::Result<()> {
        loop {
            // Note: Make sure these are all cancel-safe
            tokio::select! {
                // TODO: Is this cancel-safe?
                ready = pipe.ready(tokio::io::Interest::READABLE) => {
                    tracing::trace!("waking up to read");
                    // Zero bytes just to see if any data is ready at all
                    let mut buf = [];
                    if ready?.is_readable() && pipe.try_read(&mut buf).is_ok() {
                        match Self::read(&mut pipe).await? {
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

    async fn read(pipe: &mut named_pipe::NamedPipeServer) -> anyhow::Result<WorkerMsg> {
        read_deserialize(pipe)
            .await
            .context("ipc::Server couldn't read")
    }

    fn client_pid(pipe: &named_pipe::NamedPipeServer) -> anyhow::Result<u32> {
        let handle = pipe.as_handle();
        let handle = HANDLE(unsafe { handle.as_raw_handle().offset_from(std::ptr::null()) });
        let mut pid = 0;
        // SAFETY: Not sure if this can be called from two threads at once?
        // But the pointer is valid at least.
        unsafe { GetNamedPipeClientProcessId(handle, &mut pid) }?;
        Ok(pid)
    }
}

/// A client that's connected to a server
///
/// Manual testing shows that if the corresponding Server's process crashes, Windows will
/// be nice and return errors for anything trying to read from the Client
pub(crate) struct Client {
    pipe_task: JoinHandle<anyhow::Result<()>>,
    pub request_rx: mpsc::Receiver<ManagerMsg>,
    write_tx: mpsc::Sender<ClientInternalMsg>,
}

enum ClientInternalMsg {
    Msg(WorkerMsg),
    Shutdown,
}

impl Client {
    /// Creates a `Client`. Requires a Tokio context
    ///
    /// Doesn't block, will fail instantly if the server isn't ready
    #[tracing::instrument(skip_all)]
    pub fn new(server_id: &str) -> anyhow::Result<Self> {
        let pipe = named_pipe::ClientOptions::new().open(server_id)?;
        let (request_tx, request_rx) = mpsc::channel(5);
        let (write_tx, write_rx) = mpsc::channel(5);

        // TODO: Make sure this task stops
        let pipe_task =
            tokio::task::spawn(async move { Self::pipe_task(pipe, request_tx, write_rx).await });

        Ok(Self {
            pipe_task,
            request_rx,
            write_tx,
        })
    }

    pub async fn close(self) -> anyhow::Result<()> {
        // Worker signals its pipe task to shut down
        self.write_tx
            .send(ClientInternalMsg::Shutdown)
            .await
            .context("couldn't send ClientInternalMsg::Shutdown")?;
        let Self { pipe_task, .. } = self;
        pipe_task
            .await
            .context("async runtime error for ipc::Client::pipe_task")?
            .context("ipc::Client::pipe_task returned an error")?;
        Ok(())
    }

    pub async fn send(&self, msg: WorkerMsg) -> anyhow::Result<()> {
        self.write_tx.send(ClientInternalMsg::Msg(msg)).await?;
        Ok(())
    }

    #[tracing::instrument(skip_all)]
    async fn pipe_task(
        mut pipe: named_pipe::NamedPipeClient,
        request_tx: mpsc::Sender<ManagerMsg>,
        mut write_rx: mpsc::Receiver<ClientInternalMsg>,
    ) -> anyhow::Result<()> {
        loop {
            // Note: Make sure these are all cancel-safe
            tokio::select! {
                // TODO: Is this cancel-safe?
                ready = pipe.ready(tokio::io::Interest::READABLE) => {
                    // Zero bytes just to see if any data is ready at all
                    let mut buf = [];
                    if ready?.is_readable() && pipe.try_read(&mut buf).is_ok() {
                        let req = read_deserialize(&mut pipe).await?;
                        request_tx.send(req).await?;
                    }
                },
                // Cancel-safe per <https://docs.rs/tokio/latest/tokio/sync/mpsc/struct.Receiver.html#cancel-safety>
                msg = write_rx.recv() => {
                    let Some(msg) = msg else {
                        bail!("Client::write_rx closed suddenly");
                    };
                    let msg = match msg {
                        ClientInternalMsg::Shutdown => break,
                        ClientInternalMsg::Msg(msg) => msg,
                    };
                    write_serialize(&mut pipe, &msg).await?;
                }
            }
        }

        // Worker's pipe task closes its end of the pipe cleanly and joins
        pipe.shutdown().await?;
        tracing::debug!("Client::pipe_task exiting gracefully");
        Ok(())
    }
}

/// Reads a message from an async reader, with a 32-bit little-endian length prefix
#[tracing::instrument(skip(reader))]
async fn read_deserialize<R: AsyncRead + Unpin, T: std::fmt::Debug + DeserializeOwned>(
    reader: &mut R,
) -> Result<T, Error> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf).await?;
    let len = u32::from_le_bytes(len_buf);
    tracing::trace!(?len, "reading message");
    let len = usize::try_from(len).map_err(|_| Error::MessageLength)?;
    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf).await?;
    let buf = String::from_utf8(buf)?;
    let msg = serde_json::from_str(&buf)?;
    tracing::trace!(?msg, "read message");
    Ok(msg)
}

/// Writes a message to an async writer, with a 32-bit little-endian length prefix
#[tracing::instrument(skip(writer))]
async fn write_serialize<W: AsyncWrite + Unpin, T: std::fmt::Debug + Serialize>(
    writer: &mut W,
    msg: &T,
) -> Result<(), Error> {
    // Using JSON because `bincode` couldn't decode `ResourceDescription`
    let buf = serde_json::to_string(msg)?;
    let len = u32::try_from(buf.len())
        .map_err(|_| Error::MessageLength)?
        .to_le_bytes();
    tracing::trace!(len = buf.len(), "writing message");
    writer.write_all(&len).await?;
    writer.write_all(buf.as_bytes()).await?;
    Ok(())
}

/// `std::process::Child` but for a subcommand running from the same exe as
/// the current process.
///
/// Unlike `std::process::Child`, `Drop` tries to join the process, and kills it
/// if it can't.
pub(crate) struct SubcommandChild {
    process: Child,
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
    pub fn new(args: &[&str]) -> anyhow::Result<Self> {
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
    pub fn wait_or_kill(&mut self) -> anyhow::Result<SubcommandExit> {
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
    pub async fn wait_then_kill(&mut self, dur: Duration) -> anyhow::Result<SubcommandExit> {
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
    job_object: HANDLE,
}

impl LeakGuard {
    pub fn new() -> anyhow::Result<Self> {
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

    pub fn add_process(&self, process: &Child) -> anyhow::Result<()> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::runtime::Runtime;

    /// Because it turns out `bincode` can't deserialize `ResourceDescription` or something.
    #[test]
    fn round_trip_serde() -> anyhow::Result<()> {
        let cb: WorkerMsg = WorkerMsg::Callback(Callback::OnUpdateResources(sample_resources()));

        let v = serde_json::to_string(&cb)?;
        let roundtripped: WorkerMsg = serde_json::from_str(&v)?;

        assert_eq!(roundtripped, cb);

        Ok(())
    }

    /// Test just the happy path
    /// It's hard to simulate a process crash because:
    /// - If I Drop anything, Tokio will clean it up
    /// - If I `std::mem::forget` anything, the test process is still running, so Windows will not clean it up
    #[test]
    #[tracing::instrument(skip_all)]
    fn happy_path() -> anyhow::Result<()> {
        tracing_subscriber::fmt::try_init().ok();

        let rt = Runtime::new()?;
        rt.block_on(async move {
            // Pretend we're in the main process
            let (server, server_id) = UnconnectedServer::new()?;

            let worker_task = tokio::spawn(async move {
                // Pretend we're in a worker process
                let mut client = Client::new(&server_id)?;

                client
                    .send(WorkerMsg::Callback(Callback::OnUpdateResources(
                        sample_resources(),
                    )))
                    .await?;

                // Handle requests from the main process
                loop {
                    let Some(req) = client.request_rx.recv().await else {
                        tracing::debug!("shutting down worker_task");
                        break;
                    };
                    tracing::debug!(?req, "worker_task got request");
                    let resp = WorkerMsg::Response(req.clone());
                    client.send(resp).await?;

                    if let ManagerMsg::Disconnect = req {
                        break;
                    }
                }
                client.close().await?;
                Ok::<_, anyhow::Error>(())
            });

            let mut server = server.accept().await?;

            let start_time = Instant::now();

            let cb = server
                .cb_rx
                .recv()
                .await
                .context("should have gotten a OnUpdateResources callback")?;
            assert_eq!(cb, Callback::OnUpdateResources(sample_resources()));

            server.send(ManagerMsg::Connect).await?;
            assert_eq!(
                server.response_rx.recv().await.unwrap(),
                ManagerMsg::Connect
            );
            server.send(ManagerMsg::Connect).await?;
            assert_eq!(
                server.response_rx.recv().await.unwrap(),
                ManagerMsg::Connect
            );

            let elapsed = start_time.elapsed();
            assert!(elapsed < Duration::from_millis(20), "{:?}", elapsed);

            server.close().await?;

            // Make sure the worker 'process' exited
            worker_task.await??;

            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }
}
