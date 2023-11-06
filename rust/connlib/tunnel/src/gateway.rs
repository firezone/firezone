use crate::control_protocol::new_peer_connection;
use crate::device_channel::create_iface;
use crate::{
    PeerConfig, RoleState, Tunnel, ICE_GATHERING_TIMEOUT_SECONDS, MAX_CONCURRENT_ICE_GATHERING,
};
use chrono::{DateTime, Utc};
use connlib_shared::messages::{
    ClientId, Interface as InterfaceConfig, Relay, ResourceDescription,
};
use connlib_shared::{Callbacks, Error};
use either::Either;
use futures::channel::mpsc;
use futures_bounded::{FuturesMap, PushError, StreamMap};
use futures_util::stream::{BoxStream, SelectAll};
use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use std::task::{Context, Poll, Waker};
use std::time::Duration;
use webrtc::data::data_channel::DataChannel;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::RTCPeerConnection;

impl<CB> Tunnel<CB, State>
where
    CB: Callbacks + 'static,
{
    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_interface(&self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        let device = Arc::new(create_iface(config, self.callbacks()).await?);

        self.device.store(Some(device.clone()));
        self.no_device_waker.wake();

        tracing::debug!("background_loop_started");

        Ok(())
    }

    /// Clean up a connection to a resource.
    // FIXME: this cleanup connection is wrong!
    pub fn cleanup_connection(&self, id: ClientId) {
        self.peer_connections.lock().remove(&id);
    }
}

/// [`Tunnel`] state specific to gateways.
pub struct State {
    candidate_receivers: StreamMap<ClientId, RTCIceCandidateInit>,
    #[allow(clippy::type_complexity)]
    active_clients: SelectAll<
        BoxStream<
            'static,
            (
                ClientId,
                Arc<DataChannel>,
                PeerConfig,
                ResourceDescription,
                DateTime<Utc>,
            ),
        >,
    >,
    #[allow(clippy::type_complexity)]
    pending_peer_connections: FuturesMap<
        (ClientId, String),
        Result<
            (
                Arc<RTCPeerConnection>,
                RTCSessionDescription,
                mpsc::Receiver<RTCIceCandidateInit>,
                PeerConfig,
                ResourceDescription,
                DateTime<Utc>,
            ),
            Error,
        >,
    >,
    waker: Option<Waker>,
}

impl State {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new_peer_connection(
        &mut self,
        client: ClientId,
        phoenix_reference: String,
        peer: PeerConfig,
        resource: ResourceDescription,
        expires_at: DateTime<Utc>,
        webrtc_api: Arc<webrtc::api::API>,
        relays: Vec<Relay>,
        sdp: RTCSessionDescription,
    ) {
        let _ = self
            .pending_peer_connections
            .try_push((client, phoenix_reference), async move {
                let (peer_connection, receiver) =
                    new_peer_connection(webrtc_api.as_ref(), relays).await?;
                peer_connection.set_remote_description(sdp).await?;

                // TODO: remove tunnel IP from answer
                let answer = peer_connection.create_answer(None).await?;
                peer_connection.set_local_description(answer).await?;
                let local_desc = peer_connection
                    .local_description()
                    .await
                    .ok_or(Error::ConnectionEstablishError)?;

                Ok((
                    peer_connection,
                    local_desc,
                    receiver,
                    peer,
                    resource,
                    expires_at,
                ))
            });
    }

    fn add_new_ice_receiver(
        &mut self,
        id: ClientId,
        receiver: mpsc::Receiver<RTCIceCandidateInit>,
    ) {
        match self.candidate_receivers.try_push(id, receiver) {
            Ok(()) => {}
            Err(PushError::BeyondCapacity(_)) => {
                tracing::warn!("Too many active ICE candidate receivers at a time")
            }
            Err(PushError::Replaced(_)) => {
                tracing::warn!(%id, "Replaced old ICE candidate receiver with new one")
            }
        }
    }

    pub(crate) fn poll_next_event(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Either<Event, InternalEvent>> {
        loop {
            match self.pending_peer_connections.poll_unpin(cx) {
                Poll::Ready((
                    (client, phoenix_reference),
                    Ok(Ok((connection, local_sdp, ice_receiver, peer, resource, expires_at))),
                )) => {
                    self.add_new_ice_receiver(client, ice_receiver);

                    let (sender, receiver) = mpsc::channel(0);

                    connection.on_data_channel(Box::new(move |d| {
                        tracing::trace!("new_data_channel");
                        let data_channel = Arc::clone(&d);
                        let mut sender = sender.clone();
                        Box::pin(async move {
                            d.on_open(Box::new(move || {
                                tracing::trace!("new_data_channel_open");
                                Box::pin(async move {
                                    let data_channel = data_channel.detach().await.expect("only fails if not opened or not enabled, both of which are always true for us");

                                    let _ = sender.send(data_channel).await;
                                })
                            }))
                        })
                    }));
                    self.active_clients.push(
                        receiver
                            .map(move |c| (client, c, peer.clone(), resource.clone(), expires_at))
                            .boxed(),
                    );
                    if let Some(waker) = self.waker.take() {
                        waker.wake()
                    }
                    return Poll::Ready(Either::Right(InternalEvent::ConnectionConfigured {
                        client,
                        reference: phoenix_reference,
                        connection,
                        local_sdp,
                    }));
                }
                _ => {
                    // TODO
                }
            }

            match self.candidate_receivers.poll_next_unpin(cx) {
                Poll::Ready((conn_id, Some(Ok(c)))) => {
                    return Poll::Ready(Either::Left(Event::SignalIceCandidate {
                        conn_id,
                        candidate: c,
                    }))
                }
                Poll::Ready((id, Some(Err(e)))) => {
                    tracing::warn!(gateway_id = %id, "ICE gathering timed out: {e}");
                    continue;
                }
                Poll::Ready((_, None)) => {
                    continue;
                }
                Poll::Pending => {}
            }

            match self.active_clients.poll_next_unpin(cx) {
                Poll::Ready(Some((client, channel, config, resource, expires_at))) => {
                    return Poll::Ready(Either::Right(InternalEvent::NewPeer {
                        id: client,
                        config,
                        channel,
                        resource,
                        expires_at,
                    }))
                }
                Poll::Ready(None) => {
                    self.waker = Some(cx.waker().clone());
                    return Poll::Pending;
                }
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }
}

impl Default for State {
    fn default() -> Self {
        Self {
            candidate_receivers: StreamMap::new(
                Duration::from_secs(ICE_GATHERING_TIMEOUT_SECONDS),
                MAX_CONCURRENT_ICE_GATHERING,
            ),
            active_clients: SelectAll::new(),
            pending_peer_connections: FuturesMap::new(Duration::from_secs(5), 10),
            waker: None,
        }
    }
}

impl RoleState for State {
    type Id = ClientId;
}

#[allow(clippy::large_enum_variant)]
pub(crate) enum InternalEvent {
    ConnectionConfigured {
        client: ClientId,
        /// The `reference` of the request event in the phoenix channel.
        reference: String,
        connection: Arc<RTCPeerConnection>,
        local_sdp: RTCSessionDescription,
    },
    NewPeer {
        id: ClientId,
        config: PeerConfig,
        channel: Arc<DataChannel>,
        resource: ResourceDescription,
        expires_at: DateTime<Utc>,
    },
}

#[allow(clippy::large_enum_variant)]
pub enum Event {
    SignalIceCandidate {
        conn_id: ClientId,
        candidate: RTCIceCandidateInit,
    },
    ConnectionConfigured {
        client: ClientId,
        reference: String,
        local_sdp: RTCSessionDescription,
    },
}
