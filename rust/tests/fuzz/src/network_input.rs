use std::net::SocketAddr;

use anyhow::ErrorExt as _;
use connlib_model::{ClientId, GatewayId};
use tunnel_proto::FailedToDecapsulate;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct MalformedNetworkDatagramInput {
    target: NetworkInputTarget,
    local: SocketAddr,
    from: SocketAddr,
    payload: Vec<u8>,
}

impl MalformedNetworkDatagramInput {
    /// The largest payload that is shorter than every supported network protocol header.
    pub(crate) const MAX_PAYLOAD_LEN: usize = 3;

    pub(crate) fn new(
        target: NetworkInputTarget,
        local: SocketAddr,
        from: SocketAddr,
        payload: Vec<u8>,
    ) -> Self {
        assert_eq!(local.is_ipv4(), from.is_ipv4());
        assert!(payload.len() <= Self::MAX_PAYLOAD_LEN);

        Self {
            target,
            local,
            from,
            payload,
        }
    }

    pub(crate) fn target(&self) -> NetworkInputTarget {
        self.target
    }

    pub(crate) fn local(&self) -> SocketAddr {
        self.local
    }

    pub(crate) fn from(&self) -> SocketAddr {
        self.from
    }

    pub(crate) fn payload(&self) -> &[u8] {
        &self.payload
    }

    pub(crate) fn expected_observation(&self) -> NetworkInputObservation {
        NetworkInputObservation {
            input: self.clone(),
            outcome: NetworkInputOutcome::RejectedAsMalformed,
        }
    }

    pub(crate) fn observe<T>(&self, result: anyhow::Result<Option<T>>) -> NetworkInputObservation {
        let outcome = match result {
            Ok(Some(_)) => NetworkInputOutcome::AcceptedWithPacket,
            Ok(None) => NetworkInputOutcome::AcceptedWithoutPacket,
            Err(error) if error.any_downcast_ref::<FailedToDecapsulate>().is_some() => {
                NetworkInputOutcome::RejectedAsMalformed
            }
            Err(_) => NetworkInputOutcome::OtherError,
        };

        NetworkInputObservation {
            input: self.clone(),
            outcome,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum NetworkInputTarget {
    Client(ClientId),
    Gateway(GatewayId),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct NetworkInputObservation {
    input: MalformedNetworkDatagramInput,
    outcome: NetworkInputOutcome,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum NetworkInputOutcome {
    AcceptedWithPacket,
    AcceptedWithoutPacket,
    RejectedAsMalformed,
    OtherError,
}
