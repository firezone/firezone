use crate::server::AllocationId;
use crate::udp_socket::UdpSocket;
use anyhow::{bail, Result};
use futures::channel::mpsc;
use futures::{SinkExt, StreamExt};
use std::convert::Infallible;
use std::net::{Ipv4Addr, SocketAddr};
use tokio::task;

pub struct Allocation {
    id: AllocationId,

    /// The handle to the task that is running the allocation.
    ///
    /// Stored here to make resource-cleanup easy.
    handle: task::JoinHandle<()>,
    sender: mpsc::Sender<(Vec<u8>, SocketAddr)>,
}

impl Allocation {
    pub fn new(
        relay_data_sender: mpsc::Sender<(Vec<u8>, SocketAddr, AllocationId)>,
        id: AllocationId,
        listen_ip4_addr: Ipv4Addr,
        port: u16,
    ) -> Self {
        let (client_to_peer_sender, client_to_peer_receiver) = mpsc::channel(10);

        let task = tokio::spawn(async move {
            let Err(e) = forward_incoming_relay_data(relay_data_sender, client_to_peer_receiver, id, listen_ip4_addr, port).await else {
                unreachable!()
            };

            // TODO: Do we need to clean this up in the server? It will eventually timeout if not refreshed.
            tracing::warn!("Allocation task for {id} failed: {e}");
        });

        Self {
            id,
            handle: task,
            sender: client_to_peer_sender,
        }
    }

    /// Send data to a peer on this allocation.
    pub fn send(&mut self, data: Vec<u8>, recipient: SocketAddr) -> Result<()> {
        match self.sender.try_send((data, recipient)) {
            Ok(()) => Ok(()),
            Err(e) if e.is_disconnected() => {
                tracing::warn!(allocation = %self.id, %recipient, "Channel to allocation is disconnected");
                bail!("Channel to allocation {} is disconnected", self.id)
            }
            Err(e) if e.is_full() => {
                tracing::warn!(allocation = %self.id, "Send buffer for allocation is full, dropping packet");
                Ok(())
            }
            Err(_) => {
                // Fail in debug, but not in release mode.
                debug_assert!(false, "TrySendError only has two variants");
                Ok(())
            }
        }
    }
}

impl Drop for Allocation {
    fn drop(&mut self) {
        self.handle.abort();
    }
}

async fn forward_incoming_relay_data(
    mut relayed_data_sender: mpsc::Sender<(Vec<u8>, SocketAddr, AllocationId)>,
    mut client_to_peer_receiver: mpsc::Receiver<(Vec<u8>, SocketAddr)>,
    id: AllocationId,
    listen_ip4_addr: Ipv4Addr,
    port: u16,
) -> Result<Infallible> {
    let mut socket = UdpSocket::bind((listen_ip4_addr, port)).await?;

    loop {
        tokio::select! {
            result = socket.recv() => {
                let (data, sender) = result?;
                relayed_data_sender.send((data.to_vec(), sender, id)).await?;
            }

            Some((data, recipient)) = client_to_peer_receiver.next() => {
                socket.send_to(&data, recipient).await?;
            }
        }
    }
}
