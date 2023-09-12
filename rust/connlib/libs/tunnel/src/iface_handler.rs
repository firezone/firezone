use std::{net::IpAddr, sync::Arc, time::Duration};

use boringtun::noise::{errors::WireGuardError, Tunn, TunnResult};
use bytes::Bytes;
use libs_common::{Callbacks, Error, Result};
use tokio::{
    io::{AsyncReadExt, BufReader, ReadHalf},
    sync::mpsc::Sender,
};

use crate::{
    device_channel::{DeviceIo, IfaceConfig},
    dns,
    peer::EncapsulatedPacket,
    ControlSignal, Tunnel, MAX_UDP_SIZE,
};

const MAX_SIGNAL_CONNECTION_DELAY: Duration = Duration::from_secs(2);

impl<C, CB> Tunnel<C, CB>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    #[tracing::instrument(level = "trace", skip(self, src))]
    fn connection_intent(self: &Arc<Self>, src: &[u8], dst_addr: &IpAddr) {
        // We can buffer requests here but will drop them for now and let the upper layer reliability protocol handle this
        if let Some(resource) = self.get_resource(&src) {
            // We have awaiting connection to prevent a race condition where
            // create_peer_connection hasn't added the thing to peer_connections
            // and we are finding another packet to the same address (otherwise we would just use peer_connections here)
            let mut awaiting_connection = self.awaiting_connection.lock();
            let id = resource.id();
            if awaiting_connection.get(&id).is_none() {
                tracing::trace!(
                    message = "Found new intent to send packets to resource",
                    resource_ip = %dst_addr
                );

                awaiting_connection.insert(id, Default::default());
                let dev = Arc::clone(self);

                let mut connected_gateway_ids: Vec<_> = dev
                    .gateway_awaiting_connection
                    .lock()
                    .clone()
                    .into_keys()
                    .collect();
                connected_gateway_ids
                    .extend(dev.resources_gateways.lock().values().collect::<Vec<_>>());
                tracing::trace!(
                    message = "Currently connected gateways", gateways = ?connected_gateway_ids
                );
                tokio::spawn(async move {
                    let mut interval = tokio::time::interval(MAX_SIGNAL_CONNECTION_DELAY);
                    loop {
                        interval.tick().await;
                        let reference = {
                            let mut awaiting_connections = dev.awaiting_connection.lock();
                            let Some(awaiting_connection) =
                                awaiting_connections.get_mut(&resource.id())
                            else {
                                break;
                            };
                            if awaiting_connection.response_recieved {
                                break;
                            }
                            awaiting_connection.total_attemps += 1;
                            awaiting_connection.total_attemps
                        };
                        if let Err(e) = dev
                            .control_signaler
                            .signal_connection_to(&resource, &connected_gateway_ids, reference)
                            .await
                        {
                            // Not a deadlock because this is a different task
                            dev.awaiting_connection.lock().remove(&id);
                            tracing::error!(message = "couldn't start protocol for new connection to resource", error = ?e);
                            let _ = dev.callbacks.on_error(&e);
                        }
                    }
                });
            }
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    async fn handle_encapsulated_packet<'a>(
        &self,
        encapsulated_packet: EncapsulatedPacket<'a>,
        dst_addr: &IpAddr,
    ) -> Result<()> {
        match encapsulated_packet.encapsulate_result {
            TunnResult::Done => Ok(()),
            TunnResult::Err(WireGuardError::ConnectionExpired)
            | TunnResult::Err(WireGuardError::NoCurrentSession) => {
                self.stop_peer(encapsulated_packet.index, encapsulated_packet.conn_id)
                    .await;
                Ok(())
            }

            TunnResult::Err(e) => {
                tracing::error!(message = "Encapsulate error for resource", resource_address = %dst_addr, error = ?e);
                let err = e.into();
                let _ = self.callbacks.on_error(&err);
                return Err(err);
            }
            TunnResult::WriteToNetwork(packet) => {
                tracing::trace!(action = "writing", from = "iface", to = %dst_addr);
                if let Err(e) = encapsulated_packet
                    .channel
                    .write(&Bytes::copy_from_slice(packet))
                    .await
                {
                    tracing::error!("Couldn't write packet to channel: {e}");
                    if matches!(
                        e,
                        webrtc::data::Error::ErrStreamClosed
                            | webrtc::data::Error::Sctp(webrtc::sctp::Error::ErrStreamClosed)
                    ) {
                        self.stop_peer(encapsulated_packet.index, encapsulated_packet.conn_id)
                            .await;
                    }
                    let err = e.into();
                    let _ = self.callbacks.on_error(&err);
                    Err(err)
                } else {
                    Ok(())
                }
            }
            _ => panic!("Unexpected result from encapsulate"),
        }
    }

    #[tracing::instrument(level = "trace", skip(self, src, dst))]
    pub(crate) async fn handle_iface_packet(
        self: &Arc<Self>,
        device_writer: &Sender<Vec<u8>>,
        src: &mut [u8],
        dst: &mut [u8],
    ) -> Result<()> {
        if let Some(r) = self.check_for_dns(&src) {
            match r {
                dns::SendPacket::Ipv4(r) => self.write4_device_infallible(&device_writer, &r[..]),
                dns::SendPacket::Ipv6(r) => self.write6_device_infallible(&device_writer, &r[..]),
            }
            return Ok(());
        }

        let dst_addr = match Tunn::dst_address(&src) {
            Some(addr) => addr,
            None => return Err(Error::BadPacket),
        };

        let encapsulated_packet = {
            match self.peers_by_ip.read().longest_match(dst_addr).map(|p| p.1) {
                Some(peer) => peer.encapsulate(src, dst)?,
                None => {
                    self.connection_intent(src, &dst_addr);
                    return Ok(());
                }
            }
        };

        self.handle_encapsulated_packet(encapsulated_packet, &dst_addr)
            .await
    }

    #[tracing::instrument(
        level = "trace",
        skip(self, iface_config, device_reader, device_writer)
    )]
    pub(crate) async fn iface_handler(
        self: &Arc<Self>,
        iface_config: Arc<IfaceConfig>,
        mut device_reader: BufReader<ReadHalf<DeviceIo>>,
        device_writer: Sender<Vec<u8>>,
    ) {
        loop {
            let mut src = [0u8; MAX_UDP_SIZE];
            let mut dst = [0u8; MAX_UDP_SIZE];
            let res = {
                // TODO: We should check here if what we read is a whole packet
                // there's no docs on tun device on when a whole packet is read, is it \n or another thing?
                // found some comments saying that a single read syscall represents a single packet but no docs on that
                // See https://stackoverflow.com/questions/18461365/how-to-read-packet-by-packet-from-linux-tun-tap
                match device_reader.read(&mut src[..iface_config.mtu()]).await {
                    Ok(res) => res,
                    Err(e) => {
                        tracing::error!(error = ?e, "Couldn't read packet from interface");
                        let _ = self.callbacks.on_error(&e.into());
                        continue;
                    }
                }
            };

            tracing::trace!(action = "reading", bytes = res, from = "iface");
            // TODO
            let _ = self
                .handle_iface_packet(&device_writer, &mut src[..res], &mut dst)
                .await;
        }
    }
}
