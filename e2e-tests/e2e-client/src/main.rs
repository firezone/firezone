use std::env;

use anyhow::{Context, Result};
use control_types::Command;
use futures_util::{SinkExt, StreamExt};
use tokio::{
    net::{TcpListener, TcpStream},
    task::JoinHandle,
};

const CONTROL_ADDRESS: &str = "CONTROL_ADDRESS";

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    let control_address = env::var(CONTROL_ADDRESS).unwrap_or_else(|_| {
        panic!("Please provide the control address, e.g. {CONTROL_ADDRESS}=0.0.0.0:7777")
    });

    let listener = TcpListener::bind(&control_address)
        .await
        .context(format!("Failed to listen on address: {}", &control_address))?;
    tracing::info!("Listening on: {control_address}");

    loop {
        match listener.accept().await {
            Ok((socket, addr)) => {
                tracing::info!("Accepted new control connection from {addr}");
                if let Err(e) = control(socket).await {
                    tracing::error!("Error while execute command {e}");
                }
            }
            Err(e) => tracing::error!("Error when accepting new connection: {e}"),
        }
    }
}

async fn control(stream: TcpStream) -> Result<()> {
    // Using websockets since it's the easier way to handle streaming connections
    // (easier even than http server, raw sockets or grpc) and we don't care about performance
    // here.
    // Also using JSON but could use any binary format, no point in doing so.
    let ws_stream = tokio_tungstenite::accept_async(stream)
        .await
        .context("Failed to create websocket connection from tcp context")?;
    let (mut write, mut read) = ws_stream.split();
    let (tx, mut rx) = tokio::sync::mpsc::channel(256);
    let sender_task = tokio::spawn(async move {
        loop {
            let result = rx.recv().await;
            write
                .send(tokio_tungstenite::tungstenite::Message::Text(
                    serde_json::to_string(&result).unwrap(),
                ))
                .await
                .expect("Error while sending message");
        }
    });
    let mut ongoing_tasks: Vec<JoinHandle<()>> = Vec::new();
    while let Some(cmd) = read.next().await {
        let cmd = cmd?;
        if cmd.is_close() {
            // ignoring result, we don't care about them orchestrator will fail or succeed
            let _ = sender_task.abort();
            for task in ongoing_tasks {
                task.abort();
            }
            return Ok(());
        }
        let tx = tx.clone();
        ongoing_tasks.push(tokio::spawn(async move {
            tx.send(
                serde_json::from_str::<Command>(
                    &cmd.into_text()
                        .expect("Received unexpected non-text message"),
                )
                .expect("Received unexpected non-command")
                .execute_command()
                .await,
            )
            .await
            .expect("Receiver is gone");
        }));
    }

    let _ = sender_task.abort();
    for task in ongoing_tasks {
        task.abort();
    }
    Ok(())
}
