use std::{
    fmt,
    net::SocketAddr,
    time::{Duration, Instant},
};

use ip_packet::IpPacket;
use is::IceAgent;
use is::IceConnectionState;
use ringbuffer::AllocRingBuffer;

use crate::IceConfig;

#[derive(Debug)]
pub(crate) enum ConnectionState {
    /// We are still running ICE to figure out, which socket to use to send data.
    Connecting {
        /// Packets we are told to send whilst we are still running ICE.
        ///
        /// These need to be encrypted and sent once the tunnel is established.
        ip_buffer: AllocRingBuffer<IpPacket>,

        /// The outbound socket of the most recently completed WG
        /// handshake, if any. Set even before ICE finishes because we
        /// can authenticate handshakes from the inbound socket alone.
        session_socket: Option<PeerSocket>,
    },
    /// A socket has been nominated.
    Connected {
        /// Our nominated socket.
        nominated_socket: PeerSocket,

        /// The outbound socket of the most recently completed WG
        /// handshake. Outbound `PacketData` rides this socket
        /// regardless of what ICE has nominated.
        session_socket: Option<PeerSocket>,

        last_activity: Instant,
    },
    /// We haven't seen application packets in a while.
    Idle {
        /// Our nominated socket.
        nominated_socket: PeerSocket,

        /// The outbound socket of the most recently completed WG
        /// handshake. Outbound `PacketData` rides this socket
        /// regardless of what ICE has nominated.
        session_socket: Option<PeerSocket>,
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
            nominated_socket,
            session_socket,
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

        let nominated_socket = *nominated_socket;
        let session_socket = *session_socket;

        self.transition_to_idle(nominated_socket, session_socket, agent, idle_ice_config);
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
        let (nominated_socket, session_socket) = match self {
            Self::Idle {
                nominated_socket,
                session_socket,
            } => (*nominated_socket, *session_socket),
            Self::Connected { last_activity, .. } => {
                *last_activity = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(
            cid,
            nominated_socket,
            session_socket,
            agent,
            default_ice_config,
            "upsert",
            now,
        );
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
        let (nominated_socket, session_socket) = match self {
            Self::Idle {
                nominated_socket,
                session_socket,
            } => (*nominated_socket, *session_socket),
            Self::Connected { last_activity, .. } => {
                *last_activity = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(
            cid,
            nominated_socket,
            session_socket,
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
        let (nominated_socket, session_socket) = match self {
            Self::Idle {
                nominated_socket,
                session_socket,
            } => (*nominated_socket, *session_socket),
            Self::Connected { last_activity, .. } => {
                *last_activity = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(
            cid,
            nominated_socket,
            session_socket,
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
        let (nominated_socket, session_socket) = match self {
            Self::Idle {
                nominated_socket,
                session_socket,
            } => (*nominated_socket, *session_socket),
            Self::Connected { last_activity, .. } => {
                *last_activity = now;
                return;
            }
            Self::Failed | Self::Connecting { .. } => return,
        };

        self.transition_to_connected(
            cid,
            nominated_socket,
            session_socket,
            agent,
            default_ice_config,
            tracing::field::debug(packet),
            now,
        );
    }

    fn transition_to_idle(
        &mut self,
        nominated_socket: PeerSocket,
        session_socket: Option<PeerSocket>,
        agent: &mut IceAgent,
        idle_ice_config: IceConfig,
    ) {
        tracing::debug!("Connection is idle");
        *self = Self::Idle {
            nominated_socket,
            session_socket,
        };
        idle_ice_config.apply(agent);
    }

    fn transition_to_connected<TId>(
        &mut self,
        cid: TId,
        nominated_socket: PeerSocket,
        session_socket: Option<PeerSocket>,
        agent: &mut IceAgent,
        default_ice_config: IceConfig,
        trigger: impl tracing::Value,
        now: Instant,
    ) where
        TId: fmt::Display,
    {
        tracing::debug!(trigger, %cid, "Connection resumed");
        *self = Self::Connected {
            nominated_socket,
            session_socket,
            last_activity: now,
        };
        default_ice_config.apply(agent);
    }

    pub(crate) fn has_nominated_socket(&self) -> bool {
        matches!(self, Self::Connected { .. } | Self::Idle { .. })
    }

    /// The nominated ICE socket, if one has been picked.
    pub(crate) fn nominated_socket(&self) -> Option<PeerSocket> {
        match self {
            Self::Connected {
                nominated_socket, ..
            }
            | Self::Idle {
                nominated_socket, ..
            } => Some(*nominated_socket),
            Self::Connecting { .. } | Self::Failed => None,
        }
    }

    /// The outbound socket of the most recently completed WG
    /// handshake, if any.
    pub(crate) fn session_socket(&self) -> Option<PeerSocket> {
        match self {
            Self::Connecting { session_socket, .. }
            | Self::Connected { session_socket, .. }
            | Self::Idle { session_socket, .. } => *session_socket,
            Self::Failed => None,
        }
    }

    /// Pin the outbound socket of the most recently completed WG
    /// handshake. No-op in the [`Self::Failed`] state.
    pub(crate) fn set_session_socket(&mut self, socket: PeerSocket) {
        match self {
            Self::Connecting { session_socket, .. }
            | Self::Connected { session_socket, .. }
            | Self::Idle { session_socket, .. } => *session_socket = Some(socket),
            Self::Failed => {}
        }
    }
}

impl fmt::Display for ConnectionState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConnectionState::Connecting { .. } => write!(f, "Connecting"),
            ConnectionState::Connected {
                nominated_socket,
                session_socket,
                ..
            } => {
                write!(
                    f,
                    "Connected({} | {:?})",
                    nominated_socket.kind(),
                    session_socket.map(|p| p.kind())
                )
            }
            ConnectionState::Idle {
                nominated_socket,
                session_socket,
            } => write!(
                f,
                "Idle({} | {:?})",
                nominated_socket.kind(),
                session_socket.map(|p| p.kind())
            ),
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

    fn kind(&self) -> &'static str {
        match self {
            PeerSocket::PeerToPeer { .. } => "PeerToPeer",
            PeerSocket::PeerToRelay { .. } => "PeerToRelay",
            PeerSocket::RelayToPeer { .. } => "RelayToPeer",
            PeerSocket::RelayToRelay { .. } => "RelayToRelay",
        }
    }
}
