use std::{
    fmt,
    time::{Duration, Instant},
};

use ip_packet::IpPacket;
use ringbuffer::AllocRingBuffer;
use str0m::IceConnectionState;
use str0m::ice::IceAgent;

use crate::{IceConfig, node::PeerSocket};

#[derive(Debug)]
pub(crate) enum ConnectionState {
    /// We are still running ICE to figure out, which socket to use to send data.
    Connecting {
        /// Packets emitted by wireguard whilst are still running ICE.
        ///
        /// This can happen if the remote's WG session initiation arrives at our socket before we nominate it.
        /// A session initiation requires a response that we must not drop, otherwise the connection setup experiences unnecessary delays.
        wg_buffer: AllocRingBuffer<Vec<u8>>,

        /// Packets we are told to send whilst we are still running ICE.
        ///
        /// These need to be encrypted and sent once the tunnel is established.
        ip_buffer: AllocRingBuffer<IpPacket>,
    },
    /// A socket has been nominated.
    Connected {
        /// Our nominated socket.
        peer_socket: PeerSocket,

        last_activity: Instant,
    },
    /// We haven't seen application packets in a while.
    Idle {
        /// Our nominated socket.
        peer_socket: PeerSocket,
    },
    /// The connection failed in an unrecoverable way and will be GC'd.
    Failed,
}

impl ConnectionState {
    pub(crate) fn poll_timeout(&self, agent: &IceAgent) -> Option<(Instant, &'static str)> {
        if agent.state() != IceConnectionState::Connected {
            return None;
        }

        match self {
            ConnectionState::Connected { last_activity, .. } => {
                Some((idle_at(*last_activity), "idle transition"))
            }
            ConnectionState::Connecting { .. }
            | ConnectionState::Idle { .. }
            | ConnectionState::Failed => None,
        }
    }

    pub(crate) fn handle_timeout(
        &mut self,
        agent: &mut IceAgent,
        idle_ice_config: IceConfig,
        now: Instant,
    ) {
        let Self::Connected {
            last_activity,
            peer_socket,
        } = self
        else {
            return;
        };

        if idle_at(*last_activity) > now {
            return;
        }

        if agent.state() != IceConnectionState::Connected {
            return;
        }

        let peer_socket = *peer_socket;

        self.transition_to_idle(peer_socket, agent, idle_ice_config);
    }

    pub(crate) fn on_upsert<TId>(
        &mut self,
        cid: TId,
        agent: &mut IceAgent,
        default_ice_config: IceConfig,
        now: Instant,
    ) where
        TId: fmt::Display,
    {
        let peer_socket = match self {
            Self::Idle { peer_socket } => *peer_socket,
            Self::Connected { last_activity, .. } => {
                *last_activity = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(cid, peer_socket, agent, default_ice_config, "upsert", now);
    }

    pub(crate) fn on_candidate<TId>(
        &mut self,
        cid: TId,
        agent: &mut IceAgent,
        default_ice_config: IceConfig,
        now: Instant,
    ) where
        TId: fmt::Display,
    {
        let peer_socket = match self {
            Self::Idle { peer_socket } => *peer_socket,
            Self::Connected { last_activity, .. } => {
                *last_activity = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(
            cid,
            peer_socket,
            agent,
            default_ice_config,
            "candidates changed",
            now,
        );
    }

    pub(crate) fn on_outgoing<TId>(
        &mut self,
        cid: TId,
        agent: &mut IceAgent,
        default_ice_config: IceConfig,
        packet: &IpPacket,
        now: Instant,
    ) where
        TId: fmt::Display,
    {
        let peer_socket = match self {
            Self::Idle { peer_socket } => *peer_socket,
            Self::Connected { last_activity, .. } => {
                *last_activity = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(
            cid,
            peer_socket,
            agent,
            default_ice_config,
            tracing::field::debug(packet),
            now,
        );
    }

    pub(crate) fn on_incoming<TId>(
        &mut self,
        cid: TId,
        agent: &mut IceAgent,
        default_ice_config: IceConfig,
        packet: &IpPacket,
        now: Instant,
    ) where
        TId: fmt::Display,
    {
        let peer_socket = match self {
            Self::Idle { peer_socket } => *peer_socket,
            Self::Connected { last_activity, .. } => {
                *last_activity = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(
            cid,
            peer_socket,
            agent,
            default_ice_config,
            tracing::field::debug(packet),
            now,
        );
    }

    fn transition_to_idle(
        &mut self,
        peer_socket: PeerSocket,
        agent: &mut IceAgent,
        idle_ice_config: IceConfig,
    ) {
        tracing::debug!("Connection is idle");
        *self = Self::Idle { peer_socket };
        idle_ice_config.apply(agent);
    }

    fn transition_to_connected<TId>(
        &mut self,
        cid: TId,
        peer_socket: PeerSocket,
        agent: &mut IceAgent,
        default_ice_config: IceConfig,
        trigger: impl tracing::Value,
        now: Instant,
    ) where
        TId: fmt::Display,
    {
        tracing::debug!(trigger, %cid, "Connection resumed");
        *self = Self::Connected {
            peer_socket,
            last_activity: now,
        };
        default_ice_config.apply(agent);
    }

    pub(crate) fn has_nominated_socket(&self) -> bool {
        matches!(self, Self::Connected { .. } | Self::Idle { .. })
    }
}

impl fmt::Display for ConnectionState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConnectionState::Connecting { .. } => write!(f, "Connecting"),
            ConnectionState::Connected { peer_socket, .. } => {
                write!(f, "Connected({})", peer_socket.kind())
            }
            ConnectionState::Idle { peer_socket } => write!(f, "Idle({})", peer_socket.kind()),
            ConnectionState::Failed => write!(f, "Failed"),
        }
    }
}

fn idle_at(last_activity: Instant) -> Instant {
    const MAX_IDLE: Duration = Duration::from_secs(20); // Must be longer than the ICE timeout otherwise we might not detect a failed connection early enough.

    last_activity + MAX_IDLE
}
