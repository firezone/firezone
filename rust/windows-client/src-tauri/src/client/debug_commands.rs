//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use crate::client::cli::Cli;
use anyhow::Result;
use tokio::runtime::Runtime;
use windows::{
    core::{ComInterface, Result as WinResult},
    Win32::{
        Networking::NetworkListManager::{
            INetworkListManager, INetworkListManagerEvents, INetworkListManagerEvents_Impl,
            NetworkListManager, NLM_CONNECTIVITY,
        },
        System::Com::{
            CoCreateInstance, CoInitializeEx, CoUninitialize, IConnectionPointContainer,
            CLSCTX_ALL, COINIT_MULTITHREADED,
        },
    },
};

// TODO: In tauri-plugin-deep-link, this is the identifier in tauri.conf.json
const PIPE_NAME: &str = "dev.firezone.client";

pub fn hostname() -> Result<()> {
    println!(
        "{:?}",
        hostname::get().ok().and_then(|x| x.into_string().ok())
    );
    Ok(())
}

/// Listen for network change events from Windows
pub fn network_changes() -> Result<()> {
    // https://kennykerr.ca/rust-getting-started/how-to-implement-com-interface.html
    #[windows_implement::implement(INetworkListManagerEvents)]
    struct EventListener {}
    impl INetworkListManagerEvents_Impl for EventListener {
        fn ConnectivityChanged(&self, newconnectivity: NLM_CONNECTIVITY) -> WinResult<()> {
            dbg!(newconnectivity);
            Ok(())
        }
    }

    unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }?;

    {
        // Safety: Make sure all the COM objects are dropped before we call
        // CoUninitialize or the program might segfault.
        let network_list_manager: INetworkListManager =
            unsafe { CoCreateInstance(&NetworkListManager, None, CLSCTX_ALL) }?;
        let cpc: IConnectionPointContainer = network_list_manager.cast()?;
        let cxn_point = unsafe { cpc.FindConnectionPoint(&INetworkListManagerEvents::IID) }?;

        let listener: INetworkListManagerEvents = EventListener {}.into();
        unsafe { cxn_point.Advise(&listener) }?;

        println!("Listening for network events for 1 minute");
        std::thread::sleep(std::time::Duration::from_secs(60));
    }

    // Required, per CoInitializeEx docs
    unsafe {
        CoUninitialize();
    }
    Ok(())
}

pub fn open_deep_link(path: &url::Url) -> Result<()> {
    tracing_subscriber::fmt::init();

    let rt = Runtime::new()?;
    rt.block_on(crate::client::deep_link::open(PIPE_NAME, path))?;
    Ok(())
}

// Copied the named pipe idea from `interprocess` and `tauri-plugin-deep-link`,
// although I believe it's considered best practice on Windows to use named pipes for
// single-instance apps.
pub fn pipe_server() -> Result<()> {
    tracing_subscriber::fmt::init();

    let rt = Runtime::new()?;
    rt.block_on(async {
        loop {
            let server = crate::client::deep_link::Server::new(PIPE_NAME)?;
            server.accept().await?;
        }
    })
}

// This is copied almost verbatim from tauri-plugin-deep-link's `register` fn, with an improvement
// that we send the deep link to a subcommand so the URL won't confuse `clap`
pub fn register_deep_link() -> Result<()> {
    crate::client::deep_link::register(PIPE_NAME)?;
    Ok(())
}

pub fn wintun(_: Cli) -> Result<()> {
    tracing_subscriber::fmt::init();

    if crate::client::elevation::check()? {
        tracing::info!("Elevated");
    } else {
        tracing::warn!("Not elevated")
    }
    Ok(())
}
