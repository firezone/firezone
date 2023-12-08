// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use Result as StdResult;
use anyhow::Result as Result;
use std::sync::Arc;
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

impl Controller {
    fn start_tunnel (&mut self) -> Result <()> {
        self.stop_tunnel()?;

        // Try to open an adapter with the name "Demo"
        let adapter = match wintun::Adapter::open(&self.wintun_lib, "Demo") {
            Ok(a) => a,
            Err(_) => {
                //If loading failed (most likely it didn't exist), create a new one
                match wintun::Adapter::create(&self.wintun_lib, "Demo", "Example manor hatch stash", None) {
                    Ok(x) => x,
                    Err(e) => {
                        eprintln!("Adapter::create failed, probably need admin privileges");
                        return Err(e.into());
                    }
                }
            }
        };

        // Specify the size of the ring buffer the wintun driver should use.
        let session = Arc::new(adapter.start_session(wintun::MAX_RING_CAPACITY)?);

        self.tunnel = Some(Tunnel {
            _adapter: adapter,
            _session: session,
        });

        Ok(())
    }

    fn stop_tunnel (&mut self) -> Result <()> {
        self.tunnel = None;
        Ok(())
    }
}

struct Tunnel {
    _adapter: Arc<wintun::Adapter>,
    _session: Arc<wintun::Session>,
}

async fn run_controller(_app: tauri::AppHandle, mut ctlr_rx: mpsc::Receiver<ControllerRequest>, wintun_lib: wintun::Wintun) -> Result<()> {
    let mut controller = Controller {
        tunnel: None,
        wintun_lib,
    };

    while let Some(req) = ctlr_rx.recv().await { match req {
        ControllerRequest::StartTunnel => {
            println!("start tunnel");
            if let Err(e) = controller.start_tunnel() {
                eprintln!("{e}");
            }
        },
        ControllerRequest::StopTunnel => {
            println!("stop tunnel");
            if let Err(e) = controller.stop_tunnel() {
                eprintln!("{e}");
            }
        },
    }}

    Ok(())
}
