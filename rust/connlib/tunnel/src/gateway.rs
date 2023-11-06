use crate::device_channel::create_iface;
use crate::{
    PeerConfig, RoleState, Tunnel, ICE_GATHERING_TIMEOUT_SECONDS, MAX_CONCURRENT_ICE_GATHERING,
};
use chrono::{DateTime, Utc};
use connlib_shared::messages::{ClientId, Interface as InterfaceConfig, ResourceDescription};
use connlib_shared::Callbacks;
use either::Either;
use futures::channel::mpsc;
use futures::channel::mpsc::Receiver;
use futures_bounded::{PushError, StreamMap};
use futures_util::stream::{BoxStream, SelectAll};
use futures_util::StreamExt;
use std::sync::Arc;
use std::task::{Context, Poll, Waker};
use std::time::Duration;
use webrtc::data::data_channel::DataChannel;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;

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
    waker: Option<Waker>,
}

impl State {
    pub(crate) fn register_new_peer_connection(
        &mut self,
        client: ClientId,
        config: PeerConfig,
        resource: ResourceDescription,
        expires_at: DateTime<Utc>,
    ) -> mpsc::Sender<Arc<DataChannel>> {
        let (sender, receiver) = mpsc::channel(0);

        self.active_clients.push(
            receiver
                .map(move |c| (client, c, config.clone(), resource.clone(), expires_at))
                .boxed(),
        );
        if let Some(waker) = self.waker.take() {
            waker.wake()
        }

        sender
    }

    pub fn add_new_ice_receiver(&mut self, id: ClientId, receiver: Receiver<RTCIceCandidateInit>) {
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
            waker: None,
        }
    }
}

impl RoleState for State {
    type Id = ClientId;
}

pub(crate) enum InternalEvent {
    NewPeer {
        id: ClientId,
        config: PeerConfig,
        channel: Arc<DataChannel>,
        resource: ResourceDescription,
        expires_at: DateTime<Utc>,
    },
}

pub enum Event {
    SignalIceCandidate {
        conn_id: ClientId,
        candidate: RTCIceCandidateInit,
    },
}
