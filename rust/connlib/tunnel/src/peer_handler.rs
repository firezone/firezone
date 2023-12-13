use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwapOption;
use bytes::Bytes;
use connlib_shared::Callbacks;
use webrtc::mux::endpoint::Endpoint;
use webrtc::util::Conn;

use crate::device_channel::Device;
use crate::peer::{PacketTransform, WriteTo};
use crate::{peer::Peer, MAX_UDP_SIZE};

pub(crate) async fn start_peer_handler<TId, TTransform>(
    device: Arc<ArcSwapOption<Device>>,
    callbacks: impl Callbacks + 'static,
    peer: Arc<Peer<TId, TTransform>>,
    channel: Arc<Endpoint>,
) where
    TId: Copy + fmt::Debug + Send + Sync + 'static,
    TTransform: PacketTransform,
{
    loop {
        let Some(device) = device.load().clone() else {
            tracing::debug!("Device temporarily not available");
            tokio::time::sleep(Duration::from_millis(100)).await;
            continue;
        };
        let result = peer_handler(&callbacks, &peer, channel.clone(), &device).await;

        if matches!(result, Err(ref err) if err.raw_os_error() == Some(9)) {
            tracing::warn!("bad_file_descriptor");
            continue;
        }

        if let Err(e) = result {
            tracing::error!(err = ?e, "peer_handle_error");
        }

        break;
    }

    tracing::debug!(peer = ?peer.stats(), "peer_stopped");
}

async fn peer_handler<TId, TTransform>(
    _callbacks: &impl Callbacks,
    peer: &Arc<Peer<TId, TTransform>>,
    channel: Arc<Endpoint>,
    device: &Device,
) -> std::io::Result<()>
where
    TId: Copy,
    TTransform: PacketTransform,
{
    let mut src_buf = [0u8; MAX_UDP_SIZE];
    let mut dst_buf = [0u8; MAX_UDP_SIZE];
    while let Ok(size) = channel.recv(&mut src_buf[..]).await {
        tracing::trace!(target: "wire", action = "read", bytes = size, from = "peer");

        // TODO: Double check that this can only happen on closed channel
        // I think it's possible to transmit a 0-byte message through the channel
        // but we would never use that.
        // We should keep track of an open/closed channel ourselves if we wanted to do it properly then.
        if size == 0 {
            break;
        }

        let src = &src_buf[..size];

        match peer.decapsulate(src, &mut dst_buf) {
            Ok(Some(WriteTo::Network(bytes))) => {
                for packet in bytes {
                    if let Err(e) = channel.send(&packet).await {
                        tracing::error!("Couldn't send packet to connected peer: {e}");
                    }
                }
            }
            Ok(Some(WriteTo::Resource(packet))) => {
                device.write(packet)?;
            }
            Ok(None) => {}
            Err(other) => {
                tracing::error!(error = ?other, "failed to handle peer packet");
            }
        }
    }

    Ok(())
}

pub(crate) async fn handle_packet(
    ep: Arc<Endpoint>,
    mut receiver: tokio::sync::mpsc::Receiver<Bytes>,
) {
    while let Some(packet) = receiver.recv().await {
        if ep.send(&packet).await.is_err() {
            tracing::warn!(target: "wire", action = "dropped", "endpoint failure");
        }
    }

    if ep.close().await.is_err() {
        tracing::warn!("failed to close endpoint");
    }

    tracing::trace!("closed endpoint");
}
