use std::net::{IpAddr, SocketAddr};

use anyhow::ErrorExt as _;
use connlib_model::{ClientId, GatewayId};
use ip_packet::IpPacket;
use tunnel_proto::{UnroutablePacket, unroutable_packet::RoutingError};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum UnroutablePacketInput {
    ClientNonTunnelSource {
        client_id: ClientId,
        packet: UdpPacketInput,
    },
    ClientSelfDestination {
        client_id: ClientId,
        packet: UdpPacketInput,
    },
    GatewayNonPeerDestination {
        gateway_id: GatewayId,
        packet: UdpPacketInput,
    },
    GatewayUnknownPeer {
        gateway_id: GatewayId,
        packet: UdpPacketInput,
    },
}

impl UnroutablePacketInput {
    pub(crate) fn target(&self) -> PacketInputTarget {
        match self {
            Self::ClientNonTunnelSource { client_id, .. } => PacketInputTarget::Client(*client_id),
            Self::ClientSelfDestination { client_id, .. } => PacketInputTarget::Client(*client_id),
            Self::GatewayNonPeerDestination { gateway_id, .. } => {
                PacketInputTarget::Gateway(*gateway_id)
            }
            Self::GatewayUnknownPeer { gateway_id, .. } => PacketInputTarget::Gateway(*gateway_id),
        }
    }

    pub(crate) fn packet(&self) -> IpPacket {
        match self {
            Self::ClientNonTunnelSource { packet, .. } => packet.to_ip_packet(),
            Self::ClientSelfDestination { packet, .. } => packet.to_ip_packet(),
            Self::GatewayNonPeerDestination { packet, .. } => packet.to_ip_packet(),
            Self::GatewayUnknownPeer { packet, .. } => packet.to_ip_packet(),
        }
    }

    pub(crate) fn expected_observation(&self) -> PacketInputObservation {
        let outcome = match self {
            Self::ClientNonTunnelSource { .. } => {
                PacketInputOutcome::Rejected(RoutingError::NotTunnelSourceIp)
            }
            Self::ClientSelfDestination { .. } => {
                PacketInputOutcome::Rejected(RoutingError::PacketToSelf)
            }
            Self::GatewayNonPeerDestination { .. } => {
                PacketInputOutcome::Rejected(RoutingError::NotAPeer)
            }
            Self::GatewayUnknownPeer { .. } => {
                PacketInputOutcome::Rejected(RoutingError::NoPeerState)
            }
        };

        PacketInputObservation {
            input: *self,
            outcome,
        }
    }

    pub(crate) fn observe<T>(&self, result: anyhow::Result<Option<T>>) -> PacketInputObservation {
        let outcome = match result {
            Ok(Some(_)) => PacketInputOutcome::AcceptedWithTransmit,
            Ok(None) => PacketInputOutcome::AcceptedWithoutTransmit,
            Err(error) => match error.any_downcast_ref::<UnroutablePacket>() {
                Some(error) => PacketInputOutcome::Rejected(error.reason()),
                None => PacketInputOutcome::OtherError,
            },
        };

        PacketInputObservation {
            input: *self,
            outcome,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PacketInputTarget {
    Client(ClientId),
    Gateway(GatewayId),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct UdpPacketInput {
    source: SocketAddr,
    destination: SocketAddr,
}

impl UdpPacketInput {
    pub(crate) fn new(
        source: IpAddr,
        destination: IpAddr,
        source_port: u16,
        dst_port: u16,
    ) -> Self {
        assert_eq!(source.is_ipv4(), destination.is_ipv4());

        Self {
            source: SocketAddr::new(source, source_port),
            destination: SocketAddr::new(destination, dst_port),
        }
    }

    fn to_ip_packet(self) -> IpPacket {
        ip_packet::make::udp_packet(
            self.source.ip(),
            self.destination.ip(),
            self.source.port(),
            self.destination.port(),
            &[],
        )
        .expect("matching IP families produce a valid UDP packet")
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PacketInputObservation {
    input: UnroutablePacketInput,
    outcome: PacketInputOutcome,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PacketInputOutcome {
    AcceptedWithTransmit,
    AcceptedWithoutTransmit,
    Rejected(RoutingError),
    OtherError,
}
