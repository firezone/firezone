// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use Result as StdResult;
use anyhow::Result as Result;
use std::{
    str::FromStr,
    sync::Arc,
};
use tokio::sync::mpsc;

#[tauri::command]
async fn start_tunnel_cmd(managed: tauri::State<'_, Managed>) -> StdResult<(), String> {
    managed.ctlr_tx.send(ControllerRequest::StartTunnel).await.map_err(|_| "sending start tunnel request".to_string())?;
    Ok(())
}

#[tauri::command]
async fn stop_tunnel_cmd(managed: tauri::State<'_, Managed>) -> StdResult<(), String> {
    managed.ctlr_tx.send(ControllerRequest::StopTunnel).await.map_err(|_| "sending stop tunnel request".to_string())?;
    Ok(())
}

struct Managed {
    ctlr_tx: mpsc::Sender<ControllerRequest>,
}

enum ControllerRequest {
    StartTunnel,
    StopTunnel,
}

fn main() -> Result<()> {
    let rt = tokio::runtime::Runtime::new()?;
    let _guard = rt.enter();

    let (ctlr_tx, ctlr_rx) = mpsc::channel(5);
    let managed = Managed {
        ctlr_tx,
    };

    // Unsafe because we are loading an arbitrary dll file
    let wintun = unsafe { wintun::load_from_path("./wintun.dll") }?;

    tauri::Builder::default()
        .manage(managed)
        .invoke_handler(tauri::generate_handler![start_tunnel_cmd, stop_tunnel_cmd])
        .setup(|app| {
            let _ctlr_task = tokio::spawn(run_controller(app.handle(), ctlr_rx, wintun));
            Ok(())
        })
        .run(tauri::generate_context!())?;
    Ok(())
}

struct Controller {
    wintun_lib: wintun::Wintun,
    tunnel: Option<Tunnel>,
}

const TUNNEL_UUID: &str = "ab722ec1-9a87-4d8c-a976-e22ed7b8f6a9";

impl Controller {
    async fn start_tunnel (&mut self) -> Result <()> {
        self.stop_tunnel().await?;

        let uuid = uuid::Uuid::from_str(TUNNEL_UUID)?;

        let adapter = match wintun::Adapter::create(&self.wintun_lib, "Firezone", "Example manor hatch stash", Some(uuid.as_u128())) {
            Ok(x) => x,
            Err(e) => {
                eprintln!("Adapter::create failed, probably need admin privileges");
                return Err(e.into());
            }
        };

        println!("Adapter has addresses {:?}", adapter.get_addresses()?);

        // Specify the size of the ring buffer the wintun driver should use.
        let session = Arc::new(adapter.start_session(wintun::MAX_RING_CAPACITY)?);

        let session_2 = Arc::clone(&session);
        let recv_task = tokio::task::spawn_blocking(move || {
            let session = session_2;

            while let Ok(pkt) = session.receive_blocking() {
                println!("Got packet! {} bytes", pkt.bytes().len());
            }
            println!("recv_task exiting gracefully");
        });

        self.tunnel = Some(Tunnel {
            _adapter: adapter,
            recv_task,
            session,
        });

        Ok(())
    }

    async fn stop_tunnel (&mut self) -> Result <()> {
        if let Some(tunnel) = self.tunnel.take() {
            tunnel.session.shutdown()?;
            tunnel.recv_task.await?;
        }
        Ok(())
    }
}

struct Tunnel {
    _adapter: Arc<wintun::Adapter>,
    recv_task: tokio::task::JoinHandle<()>,
    session: Arc<wintun::Session>,
}

async fn run_controller(_app: tauri::AppHandle, mut ctlr_rx: mpsc::Receiver<ControllerRequest>, wintun_lib: wintun::Wintun) -> Result<()> {
    let mut controller = Controller {
        tunnel: None,
        wintun_lib,
    };

    while let Some(req) = ctlr_rx.recv().await { match req {
        ControllerRequest::StartTunnel => {
            println!("start tunnel");
            if let Err(e) = controller.start_tunnel().await {
                eprintln!("{e}");
            }
        },
        ControllerRequest::StopTunnel => {
            println!("stop tunnel");
            if let Err(e) = controller.stop_tunnel().await {
                eprintln!("{e}");
            }
        },
    }}

    Ok(())
}
