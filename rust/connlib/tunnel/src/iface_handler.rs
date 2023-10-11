use std::{net::IpAddr, sync::Arc, time::Duration};

use boringtun::noise::{errors::WireGuardError, Tunn, TunnResult};
use bytes::Bytes;
use connlib_shared::{Callbacks, Error, Result};

use crate::role_state::RoleState;
use crate::{
    device_channel::{DeviceIo, IfaceConfig},
    dns,
    peer::EncapsulatedPacket,
    ConnId, ControlSignal, Tunnel, MAX_UDP_SIZE,
};

const MAX_SIGNAL_CONNECTION_DELAY: Duration = Duration::from_secs(2);

impl<C, CB, TRoleState> Tunnel<C, CB, TRoleState>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    #[inline(always)]
    fn connection_intent(self: &Arc<Self>, src: &[u8], dst_addr: &IpAddr) {
        // We can buffer requests here but will drop them for now and let the upper layer reliability protocol handle this
        if let Some(resource) = self.get_resource(src) {
            // We have awaiting connection to prevent a race condition where
            // create_peer_connection hasn't added the thing to peer_connections
            // and we are finding another packet to the same address (otherwise we would just use peer_connections here)
            let mut awaiting_connection = self.awaiting_connection.lock();
            let conn_id = ConnId::from(resource.id());
            if awaiting_connection.get(&conn_id).is_none() {
                tracing::trace!(
                    resource_ip = %dst_addr,
                    "resource_connection_intent",
                );

                awaiting_connection.insert(conn_id, Default::default());
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
                    gateways = ?connected_gateway_ids,
                    "connected_gateways"
                );
                tokio::spawn(async move {
                    let mut interval = tokio::time::interval(MAX_SIGNAL_CONNECTION_DELAY);
                    loop {
                        interval.tick().await;
                        let reference = {
                            let mut awaiting_connections = dev.awaiting_connection.lock();
                            let Some(awaiting_connection) =
                                awaiting_connections.get_mut(&ConnId::from(resource.id()))
                            else {
                                break;
                            };
                            if awaiting_connection.response_received {
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
                            dev.awaiting_connection.lock().remove(&conn_id);
                            tracing::error!(error = ?e, "start_resource_connection");
                            let _ = dev.callbacks.on_error(&e);
                        }
                    }
                });
            }
        }
    }

    #[inline(always)]
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
                tracing::error!(resource_address = %dst_addr, error = ?e, "resource_connection");
                let err = e.into();
                let _ = self.callbacks.on_error(&err);
                Err(err)
            }
            TunnResult::WriteToNetwork(packet) => {
                tracing::trace!(target: "wire", action = "writing", from = "iface", to = %dst_addr);
                if let Err(e) = encapsulated_packet
                    .channel
                    .write(&Bytes::copy_from_slice(packet))
                    .await
                {
                    tracing::error!(?e, "webrtc_write");
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

    #[inline(always)]
    async fn handle_iface_packet(
        self: &Arc<Self>,
        device_writer: &DeviceIo,
        src: &mut [u8],
        dst: &mut [u8],
    ) -> Result<()> {
        if let Some(r) = self.check_for_dns(src) {
            match r {
                dns::SendPacket::Ipv4(r) => device_writer.write4(&r[..])?,
                dns::SendPacket::Ipv6(r) => device_writer.write6(&r[..])?,
            };
            return Ok(());
        }

        let dst_addr = match Tunn::dst_address(src) {
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

    #[tracing::instrument(level = "trace", skip(self, iface_config, device_io))]
    pub(crate) async fn iface_handler(
        self: &Arc<Self>,
        iface_config: Arc<IfaceConfig>,
        device_io: DeviceIo,
    ) {
        let device_writer = device_io.clone();
        let mut src = [0u8; MAX_UDP_SIZE];
        let mut dst = [0u8; MAX_UDP_SIZE];
        loop {
            let res = match device_io.read(&mut src[..iface_config.mtu()]).await {
                Ok(res) => res,
                Err(e) => {
                    tracing::error!(err = ?e, "failed to read interface: {e:#}");
                    let _ = self.callbacks.on_error(&e.into());
                    break;
                }
            };
            tracing::trace!(target: "wire", action = "read", bytes = res, from = "iface");

            if res == 0 {
                break;
            }

            if let Err(e) = self
                .handle_iface_packet(&device_writer, &mut src[..res], &mut dst)
                .await
            {
                let _ = self.callbacks.on_error(&e);
                tracing::error!(err = ?e, "failed to handle packet {e:#}")
            }
        }
    }
}
