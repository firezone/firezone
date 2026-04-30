use std::{fmt, net::SocketAddr};

use ip_packet::IpPacket;
use ringbuffer::AllocRingBuffer;

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
    },
    /// The connection failed in an unrecoverable way and will be GC'd.
    Failed,
}

impl ConnectionState {
    pub(crate) fn has_nominated_socket(&self) -> bool {
        matches!(self, Self::Connected { .. })
    }

    /// The nominated ICE socket, if one has been picked.
    pub(crate) fn nominated_socket(&self) -> Option<PeerSocket> {
        match self {
            Self::Connected {
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
            | Self::Connected { session_socket, .. } => *session_socket,
            Self::Failed => None,
        }
    }

    /// Pin the outbound socket of the most recently completed WG
    /// handshake. No-op in the [`Self::Failed`] state.
    pub(crate) fn set_session_socket(&mut self, socket: PeerSocket) {
        match self {
            Self::Connecting { session_socket, .. }
            | Self::Connected { session_socket, .. } => *session_socket = Some(socket),
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
            ConnectionState::Failed => write!(f, "Failed"),
        }
    }
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
