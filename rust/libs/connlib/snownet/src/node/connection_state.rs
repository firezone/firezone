use std::{fmt, net::SocketAddr};

use ringbuffer::AllocRingBuffer;

#[derive(Debug)]
pub(crate) enum ConnectionState {
    /// We are still running ICE to figure out which socket to use to send data.
    Connecting {
        /// Packets emitted by wireguard whilst we are still running ICE.
        ///
        /// This can happen if the remote's WG session initiation arrives at our socket before we nominate it.
        /// A session initiation requires a response that we must not drop, otherwise the connection setup experiences unnecessary delays.
        wg_buffer: AllocRingBuffer<Vec<u8>>,

        /// Packets we are told to send whilst we are still running ICE.
        ///
        /// These need to be encrypted and sent once the tunnel is established.
        ip_buffer: AllocRingBuffer<ip_packet::IpPacket>,
    },
    /// A socket has been nominated.
    Connected {
        /// Our nominated socket.
        peer_socket: PeerSocket,

        /// A socket override applied on top of `peer_socket`.
        ///
        /// Set when an authenticated WireGuard [`HandshakeInit`](boringtun::noise::HandshakeInit) arrives from a source different from the ICE-nominated path.
        /// An init is the peer's choice of send-from socket, so it tells us where the peer wants future traffic to go.
        peer_socket_override: Option<PeerSocket>,
    },
    /// The connection failed in an unrecoverable way and will be GC'd.
    Failed,
}

impl ConnectionState {
    pub(crate) fn has_nominated_socket(&self) -> bool {
        matches!(self, Self::Connected { .. })
    }
}

impl fmt::Display for ConnectionState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConnectionState::Connecting { .. } => write!(f, "Connecting"),
            ConnectionState::Connected { peer_socket, .. } => {
                write!(f, "Connected({})", peer_socket.kind())
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
