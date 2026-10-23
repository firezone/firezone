//! What the event loop hears and says, independent of the socket it is on.
//!
//! The legacy client protocol and `/device/v1` carry the same conversation
//! for the outbound half of a device; `/device/v1` adds the served half.
//! Each socket's message types convert to and from the two enums here, so
//! the event loop reads and writes one vocabulary.

use std::collections::BTreeSet;
use std::fmt;
use std::net::{Ipv4Addr, Ipv6Addr};

use connlib_model::{DeviceId, GatewayId, IceCandidate, RelayId, ResourceId, Site};
use serde::{Serialize, de::DeserializeOwned};
use tunnel::PeerKind;
use tunnel::messages::client::{
    self, AuthorizationCreated, AuthorizationCreationFailed, ClientDeviceAccessAuthorized,
    ClientDeviceAccessDenied, ClientIceCandidateError, DeviceDomainBrowseFailed,
    DeviceDomainBrowsed, DeviceDomainResolutionFailed, DeviceDomainResolved, InitClient,
    ResourceDescription, ResourceFiltersUpdated,
};
use tunnel::messages::device::{self, CreateAuthorization, InitDevice};
use tunnel::messages::gateway;
use tunnel::messages::{
    Authorization, FlowLogsConfig, Interface, Relay, RelaysPresence, SnownetCapabilities,
};

pub use tunnel::messages::device::Capabilities;

/// A socket's encoding of the event loop's vocabulary.
pub(crate) trait Wire: Send + 'static {
    type Ingress: DeserializeOwned + Send + 'static;
    type Egress: Serialize + PartialEq + fmt::Debug + Send + 'static;

    /// The channel topic the socket joins.
    const TOPIC: &'static str;

    fn decode(msg: Self::Ingress) -> Incoming;

    /// Encodes a message, or `None` for one the socket has no words for.
    fn encode(msg: Outgoing) -> Option<Self::Egress>;
}

/// What the portal tells a device.
pub(crate) enum Incoming {
    Init(Box<Init>),
    ConfigChanged(Interface),
    RelaysPresence(RelaysPresence),

    ResourceCreatedOrUpdated(ResourceDescription),
    ResourceDeleted(ResourceId),
    ResourceFiltersUpdated(ResourceFiltersUpdated),

    IceCandidates {
        peer: DeviceId,
        candidates: Vec<IceCandidate>,
    },
    InvalidateIceCandidates {
        peer: DeviceId,
        candidates: Vec<IceCandidate>,
    },

    AuthorizationCreated(AuthorizationCreated),
    AuthorizationCreationFailed(AuthorizationCreationFailed),
    ClientDeviceAccessAuthorized(Box<ClientDeviceAccessAuthorized>),
    ClientDeviceAccessDenied(ClientDeviceAccessDenied),
    ClientIceCandidateError(ClientIceCandidateError),
    /// An authorization between this device and `peer` was revoked, whichever way it went.
    RejectAccess {
        peer: DeviceId,
        resource_id: ResourceId,
    },

    DeviceDomainResolved(DeviceDomainResolved),
    DeviceDomainResolutionFailed(DeviceDomainResolutionFailed),
    DeviceDomainBrowsed(DeviceDomainBrowsed),
    DeviceDomainBrowseFailed(DeviceDomainBrowseFailed),

    /// The portal asks this device to accept a connection from a peer.
    CreateAuthorization(Box<CreateAuthorization>),
    /// The sites this device serves changed, with the resources behind them.
    SitesServedChanged {
        sites_served: Vec<Site>,
        local_resources: Vec<gateway::ResourceDescription>,
    },
    LocalResourceCreatedOrUpdated(gateway::ResourceDescription),
    LocalResourceDeleted(ResourceId),
    /// A resource this device serves changed while a peer is authorized for it.
    ServedResourceUpdated(gateway::ResourceDescription),

    /// A message the loop has nothing to do for.
    Ignored,
}

/// The `init` message of either socket.
pub(crate) struct Init {
    pub interface: Interface,
    pub resources: Vec<ResourceDescription>,
    pub relays: Vec<Relay>,
    pub authorizations: Vec<Authorization>,
    pub flow_logs: FlowLogsConfig,
    pub account_slug: String,
    pub actor_name: String,
    pub sites_served: Vec<Site>,
    pub local_resources: Vec<gateway::ResourceDescription>,
}

/// What a device tells the portal.
#[derive(Debug)]
pub(crate) enum Outgoing {
    RequestAccess {
        resource_ids: Vec<ResourceId>,
        ipv4: Option<Ipv4Addr>,
        ipv6: Option<Ipv6Addr>,
        preferred_gateways: Vec<GatewayId>,
    },
    ResolveDeviceDomain {
        domain: String,
    },
    BrowseDeviceDomain {
        domain: String,
    },
    NoRelays {
        excluded_relay_ids: Vec<RelayId>,
    },
    IceCandidates {
        peer: DeviceId,
        kind: PeerKind,
        candidates: BTreeSet<IceCandidate>,
    },
    InvalidateIceCandidates {
        peer: DeviceId,
        kind: PeerKind,
        candidates: BTreeSet<IceCandidate>,
    },
    /// The authorization the portal asked for is installed; the peer may be released.
    AuthorizationCreated {
        reference: String,
    },
    /// What the device can do, sent whenever the portal connection comes up.
    Capabilities(Capabilities),
}

/// The legacy client protocol, `/client/v3`.
pub(crate) struct ClientWire;

impl Wire for ClientWire {
    type Ingress = client::IngressMessages;
    type Egress = client::EgressMessages;

    const TOPIC: &'static str = "client";

    fn decode(msg: Self::Ingress) -> Incoming {
        use client::IngressMessages as M;

        match msg {
            M::Init(InitClient {
                interface,
                resources,
                relays,
                authorizations,
                flow_logs,
                account_slug,
                actor_name,
            }) => Incoming::Init(Box::new(Init {
                interface,
                resources,
                relays,
                authorizations,
                flow_logs,
                account_slug,
                actor_name,
                sites_served: Vec::new(),
                local_resources: Vec::new(),
            })),
            M::ResourceCreatedOrUpdated(resource) => Incoming::ResourceCreatedOrUpdated(resource),
            M::ResourceDeleted(resource) => Incoming::ResourceDeleted(resource),
            M::GatewayIceCandidates(client::GatewayIceCandidates {
                gateway_id,
                candidates,
            }) => Incoming::IceCandidates {
                peer: gateway_id,
                candidates,
            },
            M::InvalidateGatewayIceCandidates(client::GatewayIceCandidates {
                gateway_id,
                candidates,
            }) => Incoming::InvalidateIceCandidates {
                peer: gateway_id,
                candidates,
            },
            M::ClientIceCandidates(client::ClientIceCandidates {
                client_id,
                candidates,
            }) => Incoming::IceCandidates {
                peer: client_id,
                candidates,
            },
            M::InvalidateClientIceCandidates(client::ClientIceCandidates {
                client_id,
                candidates,
            }) => Incoming::InvalidateIceCandidates {
                peer: client_id,
                candidates,
            },
            M::ConfigChanged(config) => Incoming::ConfigChanged(config.interface),
            M::RelaysPresence(presence) => Incoming::RelaysPresence(presence),
            M::AuthorizationCreated(msg) => Incoming::AuthorizationCreated(msg),
            M::AuthorizationCreationFailed(msg) => Incoming::AuthorizationCreationFailed(msg),
            M::ClientDeviceAccessAuthorized(msg) => {
                Incoming::ClientDeviceAccessAuthorized(Box::new(msg))
            }
            M::ClientDeviceAccessDenied(msg) => Incoming::ClientDeviceAccessDenied(msg),
            M::ClientIceCandidateError(msg) => Incoming::ClientIceCandidateError(msg),
            M::DeviceDomainResolved(msg) => Incoming::DeviceDomainResolved(msg),
            M::DeviceDomainResolutionFailed(msg) => Incoming::DeviceDomainResolutionFailed(msg),
            M::DeviceDomainBrowsed(msg) => Incoming::DeviceDomainBrowsed(msg),
            M::DeviceDomainBrowseFailed(msg) => Incoming::DeviceDomainBrowseFailed(msg),
            M::ResourceFiltersUpdated(msg) => Incoming::ResourceFiltersUpdated(msg),
            M::RejectAccess(client::ClientRejectAccess {
                client_id,
                resource_id,
            }) => Incoming::RejectAccess {
                peer: client_id,
                resource_id,
            },
            M::AccessAuthorizationExpiryUpdated(_) => Incoming::Ignored,
        }
    }

    fn encode(msg: Outgoing) -> Option<Self::Egress> {
        use client::EgressMessages as M;

        let encoded = match msg {
            Outgoing::RequestAccess {
                resource_ids,
                ipv4,
                ipv6,
                preferred_gateways,
            } => M::RequestAccess {
                resource_ids,
                ipv4,
                ipv6,
                preferred_gateways,
            },
            Outgoing::ResolveDeviceDomain { domain } => M::ResolveDeviceDomain { domain },
            Outgoing::BrowseDeviceDomain { domain } => M::BrowseDeviceDomain { domain },
            Outgoing::NoRelays { excluded_relay_ids } => M::NoRelays { excluded_relay_ids },
            Outgoing::IceCandidates {
                peer,
                kind: PeerKind::Gateway,
                candidates,
            } => M::NewGatewayIceCandidates(client::GatewayIceCandidates {
                gateway_id: peer,
                candidates: Vec::from_iter(candidates),
            }),
            Outgoing::IceCandidates {
                peer,
                kind: PeerKind::Client,
                candidates,
            } => M::NewClientIceCandidates(client::ClientIceCandidates {
                client_id: peer,
                candidates: Vec::from_iter(candidates),
            }),
            Outgoing::InvalidateIceCandidates {
                peer,
                kind: PeerKind::Gateway,
                candidates,
            } => M::InvalidateGatewayIceCandidates(client::GatewayIceCandidates {
                gateway_id: peer,
                candidates: Vec::from_iter(candidates),
            }),
            Outgoing::InvalidateIceCandidates {
                peer,
                kind: PeerKind::Client,
                candidates,
            } => M::InvalidateClientIceCandidates(client::ClientIceCandidates {
                client_id: peer,
                candidates: Vec::from_iter(candidates),
            }),
            // The client protocol acknowledges on the device's behalf.
            Outgoing::AuthorizationCreated { .. } => return None,
            Outgoing::Capabilities(Capabilities { iceless, .. }) => {
                M::SetSnownetCapabilities(SnownetCapabilities { iceless })
            }
        };

        Some(encoded)
    }
}

/// The unified protocol, `/device/v1`.
pub(crate) struct DeviceWire;

impl Wire for DeviceWire {
    type Ingress = device::IngressMessages;
    type Egress = device::EgressMessages;

    const TOPIC: &'static str = "device";

    fn decode(msg: Self::Ingress) -> Incoming {
        use device::IngressMessages as M;

        match msg {
            M::Init(InitDevice {
                interface,
                resources,
                relays,
                authorizations,
                flow_logs,
                account_slug,
                actor_name,
                sites_served,
                local_resources,
            }) => Incoming::Init(Box::new(Init {
                interface,
                resources,
                relays,
                authorizations,
                flow_logs,
                account_slug,
                actor_name,
                sites_served,
                local_resources,
            })),
            M::ConfigChanged(config) => Incoming::ConfigChanged(config.interface),
            M::RelaysPresence(presence) => Incoming::RelaysPresence(presence),
            M::ResourceCreatedOrUpdated(resource) => Incoming::ResourceCreatedOrUpdated(resource),
            M::ResourceDeleted(resource) => Incoming::ResourceDeleted(resource),
            M::ResourceFiltersUpdated(msg) => Incoming::ResourceFiltersUpdated(msg),
            M::SitesServedChanged(device::SitesServedChanged {
                sites_served,
                local_resources,
            }) => Incoming::SitesServedChanged {
                sites_served,
                local_resources,
            },
            M::LocalResourceCreatedOrUpdated(resource) => {
                Incoming::LocalResourceCreatedOrUpdated(resource)
            }
            M::LocalResourceDeleted(resource) => Incoming::LocalResourceDeleted(resource),
            M::ResourceUpdated(resource) => Incoming::ServedResourceUpdated(resource),
            M::IceCandidates(device::IceCandidates {
                device_id,
                candidates,
            }) => Incoming::IceCandidates {
                peer: device_id,
                candidates,
            },
            M::InvalidateIceCandidates(device::IceCandidates {
                device_id,
                candidates,
            }) => Incoming::InvalidateIceCandidates {
                peer: device_id,
                candidates,
            },
            M::CreateAuthorization(msg) => Incoming::CreateAuthorization(Box::new(msg)),
            M::AuthorizationCreated(msg) => Incoming::AuthorizationCreated(msg),
            M::AuthorizationCreationFailed(msg) => Incoming::AuthorizationCreationFailed(msg),
            M::ClientDeviceAccessAuthorized(msg) => {
                Incoming::ClientDeviceAccessAuthorized(Box::new(msg))
            }
            M::ClientDeviceAccessDenied(msg) => Incoming::ClientDeviceAccessDenied(msg),
            M::ClientIceCandidateError(msg) => Incoming::ClientIceCandidateError(msg),
            M::RejectAccess(gateway::RejectAccess {
                client_id,
                resource_id,
            }) => Incoming::RejectAccess {
                peer: client_id,
                resource_id,
            },
            M::DeviceDomainResolved(msg) => Incoming::DeviceDomainResolved(msg),
            M::DeviceDomainResolutionFailed(msg) => Incoming::DeviceDomainResolutionFailed(msg),
            M::DeviceDomainBrowsed(msg) => Incoming::DeviceDomainBrowsed(msg),
            M::DeviceDomainBrowseFailed(msg) => Incoming::DeviceDomainBrowseFailed(msg),
        }
    }

    fn encode(msg: Outgoing) -> Option<Self::Egress> {
        use device::EgressMessages as M;

        let encoded = match msg {
            Outgoing::RequestAccess {
                resource_ids,
                ipv4,
                ipv6,
                preferred_gateways,
            } => M::RequestAccess {
                resource_ids,
                ipv4,
                ipv6,
                preferred_gateways,
            },
            Outgoing::ResolveDeviceDomain { domain } => M::ResolveDeviceDomain { domain },
            Outgoing::BrowseDeviceDomain { domain } => M::BrowseDeviceDomain { domain },
            Outgoing::NoRelays { excluded_relay_ids } => M::NoRelays { excluded_relay_ids },
            Outgoing::IceCandidates {
                peer, candidates, ..
            } => M::BroadcastIceCandidates(device::BroadcastIceCandidates {
                device_ids: vec![peer],
                candidates,
            }),
            Outgoing::InvalidateIceCandidates {
                peer, candidates, ..
            } => M::BroadcastInvalidatedIceCandidates(device::BroadcastIceCandidates {
                device_ids: vec![peer],
                candidates,
            }),
            Outgoing::AuthorizationCreated { reference } => M::AuthorizationCreated { reference },
            Outgoing::Capabilities(capabilities) => M::SetCapabilities(capabilities),
        };

        Some(encoded)
    }
}
