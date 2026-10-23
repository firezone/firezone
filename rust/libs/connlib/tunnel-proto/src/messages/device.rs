//! The `/device/v1` protocol: one message set for every device.
//!
//! A device hears about the resources it may reach, as a client does, and
//! about the sites it serves and the resources behind them, as a gateway
//! does, on one socket. Peers are named by `device_id` either way, and
//! every authorization the device installs for a peer arrives as a
//! [`CreateAuthorization`] naming the [`Target`] the peer may reach.

use std::collections::BTreeSet;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::time::Duration;

use connlib_model::{DeviceId, IceCandidate, RelayId, ResourceId, Site};
use serde::{Deserialize, Serialize};
use serde_with::{DurationSeconds, serde_as};

use super::client::{
    AuthorizationCreated, AuthorizationCreationFailed, ClientDeviceAccessAuthorized,
    ClientDeviceAccessDenied, ClientIceCandidateError, ConfigUpdate, DeviceDomainBrowseFailed,
    DeviceDomainBrowsed, DeviceDomainResolutionFailed, DeviceDomainResolved, ResourceDescription,
    ResourceFiltersUpdated,
};
use super::gateway::{self, RejectAccess};
use super::{
    Authorization, Filter, FlowLogsConfig, IceCredentials, IceRole, IngestToken, Interface, Key,
    Relay, RelaysPresence, SecretKey,
};

/// The `init` message: both halves of what the device is.
#[derive(Debug, Deserialize)]
pub struct InitDevice {
    pub interface: Interface,
    #[serde(default)]
    pub resources: Vec<ResourceDescription>,
    #[serde(default)]
    pub relays: Vec<Relay>,
    /// The authorizations where this device is the receiver, to resync on (re)connect.
    #[serde(default)]
    pub authorizations: Vec<Authorization>,
    pub flow_logs: FlowLogsConfig,
    pub account_slug: String,
    pub actor_name: String,
    /// The sites the device serves.
    #[serde(default)]
    pub sites_served: Vec<Site>,
    /// Every resource behind the sites the device serves.
    #[serde(default)]
    pub local_resources: Vec<gateway::ResourceDescription>,
}

/// The device's site assignments changed, with the resources behind them.
#[derive(Debug, Deserialize)]
pub struct SitesServedChanged {
    #[serde(default)]
    pub sites_served: Vec<Site>,
    #[serde(default)]
    pub local_resources: Vec<gateway::ResourceDescription>,
}

/// What a peer is authorized to reach through this device.
#[derive(Debug, Deserialize, Clone)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Target {
    /// A resource the device serves; its description travels in [`CreateAuthorization::resource`].
    Resource { resource_id: ResourceId },
    /// The device itself, through a pool, limited by the pool's filters.
    #[serde(rename = "self")]
    Device {
        pool_id: ResourceId,
        #[serde(default)]
        filters: Vec<Filter>,
    },
}

/// The peer an authorization is for.
#[derive(Debug, Deserialize, Clone)]
pub struct Peer {
    pub id: DeviceId,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub slug: Option<String>,
    pub public_key: Key,
    pub preshared_key: SecretKey,
    pub ipv4: Ipv4Addr,
    pub ipv6: Ipv6Addr,
}

/// The portal asks the device to accept a connection from a peer for a target.
///
/// The device echoes `ref` through [`EgressMessages::AuthorizationCreated`]
/// once the authorization is installed, and only then is the peer released.
#[serde_as]
#[derive(Debug, Deserialize, Clone)]
pub struct CreateAuthorization {
    #[serde(rename = "ref")]
    pub reference: String,
    pub target: Target,
    pub client: Peer,
    pub client_ice_credentials: IceCredentials,
    /// This device's ICE credentials.
    pub gateway_ice_credentials: IceCredentials,
    /// The resource, when the target is one.
    #[serde(default)]
    pub resource: Option<gateway::ResourceDescription>,
    #[serde_as(as = "Option<DurationSeconds<u64>>")]
    #[serde(default)]
    pub expires_at: Option<Duration>,
    #[serde(default)]
    pub use_iceless: bool,
    /// The ICE role the portal assigns this side of the connection.
    #[serde(default = "controlled")]
    pub ice_role: IceRole,
    /// The responder-side ingest token for this flow's logs.
    pub flow_logs_ingest_token: IngestToken,
}

fn controlled() -> IceRole {
    IceRole::Controlled
}

/// ICE candidates to or from one peer.
#[serde_with::serde_as]
#[derive(Debug, Deserialize, Serialize, PartialEq)]
pub struct IceCandidates {
    pub device_id: DeviceId,
    #[serde_as(as = "serde_with::VecSkipError<_>")]
    pub candidates: Vec<IceCandidate>,
}

/// ICE candidates for several peers at once.
#[derive(Debug, Serialize, PartialEq, Clone)]
pub struct BroadcastIceCandidates {
    pub device_ids: Vec<DeviceId>,
    pub candidates: BTreeSet<IceCandidate>,
}

/// What the device can do, so the portal routes to it, or not.
#[derive(Debug, Serialize, PartialEq, Eq, Clone, Copy)]
pub struct Capabilities {
    /// Whether the device forwards to the resources it serves.
    pub route_resources: bool,
    /// Whether the device answers the DNS of the resources it serves.
    pub dns_recursion: bool,
    /// Whether the device connects without ICE where the portal allows.
    pub iceless: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
pub enum IngressMessages {
    Init(InitDevice),
    ConfigChanged(ConfigUpdate),
    RelaysPresence(RelaysPresence),

    ResourceCreatedOrUpdated(ResourceDescription),
    ResourceDeleted(ResourceId),
    ResourceFiltersUpdated(ResourceFiltersUpdated),

    SitesServedChanged(SitesServedChanged),
    LocalResourceCreatedOrUpdated(gateway::ResourceDescription),
    LocalResourceDeleted(ResourceId),
    /// A resource the device serves changed while a peer is authorized for it.
    ResourceUpdated(gateway::ResourceDescription),

    IceCandidates(IceCandidates),
    InvalidateIceCandidates(IceCandidates),

    CreateAuthorization(CreateAuthorization),
    AuthorizationCreated(AuthorizationCreated),
    AuthorizationCreationFailed(AuthorizationCreationFailed),
    ClientDeviceAccessAuthorized(ClientDeviceAccessAuthorized),
    ClientDeviceAccessDenied(ClientDeviceAccessDenied),
    ClientIceCandidateError(ClientIceCandidateError),
    /// An authorization between this device and a peer was revoked, whichever way it went.
    RejectAccess(RejectAccess),

    DeviceDomainResolved(DeviceDomainResolved),
    DeviceDomainResolutionFailed(DeviceDomainResolutionFailed),
    DeviceDomainBrowsed(DeviceDomainBrowsed),
    DeviceDomainBrowseFailed(DeviceDomainBrowseFailed),
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
pub enum EgressMessages {
    /// Asks for access through the named resources, most preferred first.
    RequestAccess {
        resource_ids: Vec<ResourceId>,
        #[serde(skip_serializing_if = "Option::is_none")]
        ipv4: Option<Ipv4Addr>,
        #[serde(skip_serializing_if = "Option::is_none")]
        ipv6: Option<Ipv6Addr>,
        #[serde(rename = "connected_gateway_ids")]
        preferred_gateways: Vec<DeviceId>,
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
    BroadcastIceCandidates(BroadcastIceCandidates),
    BroadcastInvalidatedIceCandidates(BroadcastIceCandidates),
    AuthorizationCreated {
        #[serde(rename = "ref")]
        reference: String,
    },
    SetCapabilities(Capabilities),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_create_authorization_for_the_device_itself() {
        let key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        let token = flow_tracker::TEST_INGEST_TOKEN;
        let json = format!(
            r#"{{
            "event": "create_authorization",
            "payload": {{
                "ref": "signed",
                "target": {{"type": "self", "pool_id": "00000000-0000-0000-0000-000000000001", "filters": [{{"protocol": "udp", "port_range_start": 53, "port_range_end": 53}}]}},
                "client": {{"id": "00000000-0000-0000-0000-000000000002", "public_key": "{key}", "preshared_key": "{key}", "ipv4": "100.64.0.2", "ipv6": "fd00:2021:1111::2"}},
                "client_ice_credentials": {{"username": "a", "password": "b"}},
                "gateway_ice_credentials": {{"username": "c", "password": "d"}},
                "ice_role": "controlling",
                "expires_at": 1700000000,
                "use_iceless": true,
                "flow_logs_ingest_token": "{token}"
            }}
        }}"#
        );

        let msg = serde_json::from_str::<IngressMessages>(&json);

        assert!(
            matches!(
                &msg,
                Ok(IngressMessages::CreateAuthorization(CreateAuthorization {
                    target: Target::Device { .. },
                    ice_role: IceRole::Controlling,
                    use_iceless: true,
                    ..
                }))
            ),
            "{msg:?}"
        );
    }

    #[test]
    fn serializes_capabilities() {
        let msg = EgressMessages::SetCapabilities(Capabilities {
            route_resources: true,
            dns_recursion: true,
            iceless: false,
        });

        assert_eq!(
            serde_json::to_string(&msg).unwrap(),
            r#"{"event":"set_capabilities","payload":{"route_resources":true,"dns_recursion":true,"iceless":false}}"#
        );
    }
}
