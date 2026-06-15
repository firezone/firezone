use std::{
    fmt,
    net::SocketAddr,
    time::{Duration, Instant},
};

use ip_packet::IpPacket;
use ringbuffer::AllocRingBuffer;

use crate::IceConfig;
use crate::agent::Agent;

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
    pub(crate) fn poll_timeout(&self, agent: &Agent) -> Option<(Instant, &'static str)> {
        if !agent.is_negotiation_complete() {
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
        agent: &mut Agent,
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

        if !agent.is_negotiation_complete() {
            return;
        }

        let peer_socket = *peer_socket;

        self.transition_to_idle(peer_socket, agent, idle_ice_config);
    }

    pub(crate) fn on_upsert<TId>(
        &mut self,
        cid: TId,
        agent: &mut Agent,
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
        agent: &mut Agent,
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
        agent: &mut Agent,
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
        agent: &mut Agent,
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
        agent: &mut Agent,
        idle_ice_config: IceConfig,
    ) {
        tracing::debug!("Connection is idle");
        *self = Self::Idle { peer_socket };
        agent.apply_ice_config(idle_ice_config);
    }

    fn transition_to_connected<TId>(
        &mut self,
        cid: TId,
        peer_socket: PeerSocket,
        agent: &mut Agent,
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
        agent.apply_ice_config(default_ice_config);
    }

    pub(crate) fn has_nominated_socket(&self) -> bool {
        matches!(self, Self::Connected { .. } | Self::Idle { .. })
    }

    /// The currently nominated socket, if any.
    pub(crate) fn peer_socket(&self) -> Option<PeerSocket> {
        match self {
            Self::Connected { peer_socket, .. } | Self::Idle { peer_socket } => Some(*peer_socket),
            Self::Connecting { .. } | Self::Failed => None,
        }
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

/// The socket of the peer we are connected to.
#[derive(PartialEq, Clone, Copy, Debug)]
pub(crate) enum PeerSocket {
    PeerToPeer {
        source: SocketAddr,
        dest: SocketAddr,
    },
    PeerToRelay {
        source: SocketAddr,
        dest: SocketAddr,
    },
    RelayToPeer {
        dest: SocketAddr,
    },
    RelayToRelay {
        dest: SocketAddr,
    },
}

impl PeerSocket {
    pub(crate) fn send_from_relay(&self) -> bool {
        matches!(self, Self::RelayToPeer { .. } | Self::RelayToRelay { .. })
    }

    pub(crate) fn fmt<RId>(&self, relay: RId) -> String
    where
        RId: fmt::Display,
    {
        match self {
            PeerSocket::PeerToPeer { source, dest } => {
                format!("PeerToPeer {{ source: {source}, dest: {dest} }}")
            }
            PeerSocket::PeerToRelay { source, dest } => {
                format!("PeerToRelay {{ source: {source}, dest: {dest} }}")
            }
            PeerSocket::RelayToPeer { dest } => {
                format!("RelayToPeer {{ relay: {relay}, dest: {dest} }}")
            }
            PeerSocket::RelayToRelay { dest } => {
                format!("RelayToRelay {{ relay: {relay}, dest: {dest} }}")
            }
        }
    }

    /// All possible values returned by [`PeerSocket::kind`], ordered by
    /// [`PeerSocket::kind_index`].
    pub(crate) const KINDS: [&'static str; 4] =
        ["PeerToPeer", "PeerToRelay", "RelayToPeer", "RelayToRelay"];

    pub(crate) fn kind(&self) -> &'static str {
        Self::KINDS[self.kind_index()]
    }

    /// Index of this socket's kind into [`PeerSocket::KINDS`].
    pub(crate) fn kind_index(&self) -> usize {
        match self {
            PeerSocket::PeerToPeer { .. } => 0,
            PeerSocket::PeerToRelay { .. } => 1,
            PeerSocket::RelayToPeer { .. } => 2,
            PeerSocket::RelayToRelay { .. } => 3,
        }
    }
}
