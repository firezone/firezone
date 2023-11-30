use crate::server::AllocationId;
use crate::udp_socket::UdpSocket;
use crate::AddressFamily;
use anyhow::{bail, Result};
use futures::channel::mpsc;
use futures::{SinkExt, StreamExt};
use std::convert::Infallible;
use std::net::SocketAddr;
use tokio::task;

/// The maximum amount of items that can be buffered in the channel to the allocation task.
const MAX_BUFFERED_ITEMS: usize = 1000;

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
        family: AddressFamily,
        port: u16,
    ) -> Self {
        let (client_to_peer_sender, client_to_peer_receiver) = mpsc::channel(MAX_BUFFERED_ITEMS);

        let task = tokio::spawn(async move {
            let Err(e) = forward_incoming_relay_data(
                relay_data_sender,
                client_to_peer_receiver,
                id,
                family,
                port,
            )
            .await
            else {
                unreachable!()
            };

            tracing::warn!(allocation = %id, %family, "Allocation task failed: {e:#}");

            // With the task stopping, the channel will be closed and any attempt to send data to it will fail.
        });

        Self {
            id,
            handle: task,
            sender: client_to_peer_sender,
        }
    }

    /// Send data to a peer on this allocation.
    ///
    /// In case the channel is full, we will simply drop the packet and log a warning.
    /// In normal operation, this should not happen but if for some reason, the allocation task cannot keep up with the incoming data, we need to drop packets somewhere to avoid unbounded memory growth.
    ///
    /// All our data is relayed over UDP which by design is an unreliable protocol.
    /// Thus, any application running on top of this relay must already account for potential packet loss.
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
    family: AddressFamily,
    port: u16,
) -> Result<Infallible> {
    let mut socket = UdpSocket::bind(family, port)?;

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
