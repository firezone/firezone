use std::{net::IpAddr, sync::Arc, time::Duration};

use boringtun::noise::{errors::WireGuardError, TunnResult};
use bytes::Bytes;
use connlib_shared::{Callbacks, Result};

use crate::ip_packet::{IpPacket, MutableIpPacket};
use crate::role_state::RoleState;
use crate::{peer::EncapsulatedPacket, ConnId, ControlSignal, Tunnel};

const MAX_SIGNAL_CONNECTION_DELAY: Duration = Duration::from_secs(2);

impl<C, CB, TRoleState> Tunnel<C, CB, TRoleState>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    #[inline(always)]
    fn connection_intent(self: &Arc<Self>, packet: IpPacket<'_>) {
        // We can buffer requests here but will drop them for now and let the upper layer reliability protocol handle this
        if let Some(resource) = self.get_resource(packet.source()) {
            // We have awaiting connection to prevent a race condition where
            // create_peer_connection hasn't added the thing to peer_connections
            // and we are finding another packet to the same address (otherwise we would just use peer_connections here)
            let mut awaiting_connection = self.awaiting_connection.lock();
            let conn_id = ConnId::from(resource.id());
            if awaiting_connection.get(&conn_id).is_none() {
                tracing::trace!(
                    resource_ip = %packet.destination(),
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
    pub(crate) async fn handle_iface_packet(
        self: &Arc<Self>,
        mut packet: MutableIpPacket<'_>,
        dst: &mut [u8],
    ) -> Result<()> {
        let dest = packet.destination();

        let encapsulated_packet = match self.peers_by_ip.read().longest_match(dest) {
            Some((_, peer)) => peer.encapsulate(&mut packet, dst)?,
            None => {
                self.connection_intent(packet.as_immutable());
                return Ok(());
            }
        };

        self.handle_encapsulated_packet(encapsulated_packet, &dest)
            .await
    }
}
