//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use crate::client::ipc;
use anyhow::Result;
use std::{
    process::{Child, Command},
    thread::sleep,
    time::Duration,
};
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};

#[derive(clap::Subcommand)]
pub enum Cmd {
    Crash,
    Hostname,
    NetworkChanges,
    Test {
        #[command(subcommand)]
        command: Test,
    },
    Wintun,
}

pub fn run(cmd: Cmd) -> Result<()> {
    match cmd {
        Cmd::Crash => crash(),
        Cmd::Hostname => hostname(),
        Cmd::NetworkChanges => network_changes(),
        Cmd::Test { command } => run_test(command),
        Cmd::Wintun => wintun(),
    }
}

fn crash() -> Result<()> {
    // `_` doesn't seem to work here, the log files end up empty
    let _handles = crate::client::logging::setup("debug")?;
    tracing::info!("started log (DebugCrash)");

    panic!("purposely crashing to see if it shows up in logs");
}

fn hostname() -> Result<()> {
    println!(
        "{:?}",
        hostname::get().ok().and_then(|x| x.into_string().ok())
    );
    Ok(())
}

/// Listen for network change events from Windows
fn network_changes() -> Result<()> {
    tracing_subscriber::fmt::init();

    // Must be called for each thread that will do COM stuff
    unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }?;

    {
        let _listener = crate::client::network_changes::Listener::new()?;
        println!("Listening for network events for 1 minute");
        std::thread::sleep(std::time::Duration::from_secs(60));
    }

    unsafe {
        // Required, per CoInitializeEx docs
        // Safety: Make sure all the COM objects are dropped before we call
        // CoUninitialize or the program might segfault.
        CoUninitialize();
    }
    Ok(())
}

fn wintun() -> Result<()> {
    tracing_subscriber::fmt::init();

    if crate::client::elevation::check()? {
        tracing::info!("Elevated");
    } else {
        tracing::warn!("Not elevated")
    }
    Ok(())
}

#[derive(clap::Subcommand)]
pub enum Test {
    Ipc,
    IpcManager { pipe_id: String },
    IpcWorker { pipe_id: String },
    LeakProcess,
    LeakManager { pipe_id: String },
    LeakWorker { pipe_id: String },
}

fn run_test(cmd: Test) -> Result<()> {
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(async move {
        match cmd {
            Test::Ipc => test_ipc(),
            Test::IpcManager { pipe_id } => ipc_manager(pipe_id).await,
            Test::IpcWorker { pipe_id } => ipc_worker(pipe_id).await,
            Test::LeakProcess => test_leak().await,
            Test::LeakManager { pipe_id } => leak_manager(pipe_id),
            Test::LeakWorker { pipe_id } => leak_worker(pipe_id).await,
        }
    })?;
    Ok(())
}

struct SubcommandChild {
    process: Child,
}

impl SubcommandChild {
    fn new(args: &[&str]) -> Result<Self> {
        let mut process = Command::new(std::env::current_exe()?);
        for arg in args {
            process.arg(arg);
        }
        let process = process.spawn()?;
        Ok(SubcommandChild { process })
    }
}

impl Drop for SubcommandChild {
    fn drop(&mut self) {
        if let Ok(Some(status)) = self.process.try_wait() {
            if status.success() {
                tracing::info!("process exited with success code");
            } else {
                tracing::warn!("process exited with non-success code");
            }
        } else if let Err(error) = self.process.kill() {
            tracing::error!(?error, "couldn't kill process");
        } else {
            tracing::error!("process was killed");
        }
    }
}

fn test_ipc() -> Result<()> {
    tracing_subscriber::fmt::init();

    let id = ipc::random_pipe_id();

    let _manager = SubcommandChild::new(&["debug", "test", "ipc-manager", &id]);
    let _worker = SubcommandChild::new(&["debug", "test", "ipc-worker", &id]);

    sleep(Duration::from_secs(10));
    Ok(())
}

async fn ipc_manager(pipe_id: String) -> Result<()> {
    tracing_subscriber::fmt::init();
    let server = ipc::UnconnectedServer::new_with_id(&pipe_id)?;

    // TODO: The real manager would spawn the worker subprocess here, but
    // for this case, the test harness spawns it for us.

    let mut server = server.connect().await?;

    let start_time = std::time::Instant::now();
    assert_eq!(
        server.request(ipc::Request::Connect).await?,
        ipc::Response::Connected
    );
    assert_eq!(
        server.request(ipc::Request::AwaitCallback).await?,
        ipc::Response::CallbackOnUpdateResources(vec![])
    );
    assert_eq!(
        server.request(ipc::Request::Disconnect).await?,
        ipc::Response::Disconnected
    );

    let elapsed = start_time.elapsed();
    assert!(
        elapsed < std::time::Duration::from_millis(6),
        "{:?}",
        elapsed
    );

    Ok(())
}

async fn ipc_worker(pipe_id: String) -> Result<()> {
    tracing_subscriber::fmt::init();
    let mut client = ipc::Client::new(&pipe_id)?;
    // panic!("Pretending the worker crashed right after connecting");

    // Handle requests from the main process
    loop {
        let (req, responder) = client.next_request().await?;
        let resp = match &req {
            ipc::Request::AwaitCallback => ipc::Response::CallbackOnUpdateResources(vec![]),
            ipc::Request::Connect => ipc::Response::Connected,
            ipc::Request::Disconnect => ipc::Response::Disconnected,
        };
        responder.respond(resp).await?;

        if let ipc::Request::Disconnect = req {
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
async fn test_leak() -> Result<()> {
    tracing_subscriber::fmt::init();

    let (server, pipe_id) = ipc::UnconnectedServer::new()?;
    let mut manager = SubcommandChild::new(&["debug", "test", "leak-manager", &pipe_id])?;
    let mut server = server.connect().await?;
    tracing::debug!("Harness accepted connection from Worker");

    // Send a few requests to make sure the worker is connected and good
    for _ in 0..3 {
        server.request(ipc::Request::AwaitCallback).await?;
    }

    tokio::time::sleep(std::time::Duration::from_secs(15)).await;

    manager.process.kill()?;
    tracing::debug!("Harness killed manager");

    // I can't think of a good way to synchronize with the worker process stopping,
    // so just give it 10 seconds for Windows to stop it.
    for _ in 0..10 {
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        if server.request(ipc::Request::AwaitCallback).await.is_err() {
            tracing::info!("confirmed worker stopped responding");
            break;
        }
    }

    assert!(
        server.request(ipc::Request::AwaitCallback).await.is_err(),
        "worker shouldn't be able to respond here"
    );
    Ok(())
}

fn leak_manager(pipe_id: String) -> Result<()> {
    let leak_guard = ipc::LeakGuard::new()?;

    let worker = SubcommandChild::new(&["debug", "test", "leak-worker", &pipe_id])?;
    // If you comment out this line the test should fail since the worker will keep running.
    leak_guard.add_process(&worker.process)?;
    tracing::debug!("Manager set up leak protection, waiting for SIGKILL");
    loop {
        std::thread::park();
    }
}

async fn leak_worker(pipe_id: String) -> Result<()> {
    tracing_subscriber::fmt::init();
    let mut client = ipc::Client::new(&pipe_id)?;
    tracing::debug!("Worker connected to named pipe");
    loop {
        let (_, responder) = client.next_request().await?;
        responder
            .respond(ipc::Response::CallbackTunnelReady)
            .await?;
    }
}
