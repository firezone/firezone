//! The `/device/v1` protocol: one message set for every device.
//!
//! A device hears about the resources it may reach, and about the sites it
//! serves with the resources behind them, on one socket. Peers are named by
//! `device_id`, never by kind: a peer may serve us, be served by us, reach us
//! through a device pool, or several of these at once.
//!
//! Both sides of a connection hear about it the same way. The receiving side
//! gets [`AuthorizePeer`] and confirms it installed the authorization by
//! echoing its [`AuthorizationRef`]. The initiating side gets
//! [`AccessGranted`] once the receiving side confirmed.

use std::collections::BTreeSet;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::time::Duration;

use connlib_model::{DeviceId, IceCandidate, RelayId, ResourceId, Site, SiteId};
use serde::{Deserialize, Serialize};
use serde_with::{DurationSeconds, VecSkipError, serde_as};

use super::client::{
    ConfigUpdate, DeviceDomainBrowseFailed, DeviceDomainBrowsed, DeviceDomainResolutionFailed,
    DeviceDomainResolved, FailReason, ResourceDescription, ResourceFiltersUpdated,
    ViolatedProperty,
};
use super::{
    Filter, FlowLogsConfig, IceCredentials, IceRole, IngestToken, Interface, Key, Relay,
    RelaysPresence, SecretKey, WarnOnInvalidFilter, gateway,
};

/// The `init` message.
#[derive(Debug, Deserialize)]
pub struct Init {
    pub interface: Interface,
    /// The resources we may reach.
    #[serde(default)]
    pub resources: Vec<ResourceDescription>,
    #[serde(default)]
    pub relays: Vec<Relay>,
    /// The sites we serve.
    #[serde(default)]
    pub served_sites: Vec<Site>,
    /// The resources behind the sites we serve.
    #[serde(default)]
    pub served_resources: Vec<gateway::ResourceDescription>,
    /// The authorizations of peers to reach a target through us, to resync on (re)connect.
    #[serde(default)]
    pub authorizations: Vec<Authorization>,
    pub flow_logs: FlowLogsConfig,
    pub account_slug: String,
    pub actor_name: String,
}

/// An active authorization: `device_id` may reach `resource_id` through us until `expires_at`.
#[serde_as]
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct Authorization {
    pub device_id: DeviceId,
    pub resource_id: ResourceId,
    #[serde_as(as = "Option<DurationSeconds<u64>>")]
    #[serde(default)]
    pub expires_at: Option<Duration>,
}

/// The sites we serve changed, with the resources behind them.
#[derive(Debug, Deserialize)]
pub struct ServedSites {
    #[serde(default)]
    pub served_sites: Vec<Site>,
    #[serde(default)]
    pub served_resources: Vec<gateway::ResourceDescription>,
}

/// Echoed back to the portal to confirm an [`AuthorizePeer`] was installed.
///
/// Opaque to the device.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(transparent)]
pub struct AuthorizationRef(String);

/// A peer at one end of a connection.
#[derive(Debug, Deserialize, Clone)]
pub struct Peer {
    pub id: DeviceId,
    pub name: String,
    pub slug: String,
    pub public_key: Key,
    pub preshared_key: SecretKey,
    pub ipv4: Ipv4Addr,
    pub ipv6: Ipv6Addr,
}

/// How a connection is established.
#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Connection {
    /// Without ICE: both peers probe every path with WireGuard handshakes.
    Frostlink,
    /// With ICE, in the role the portal picked for us.
    Ice { role: IceRole },
}

/// What a peer may reach through us.
#[serde_as]
#[derive(Debug, Deserialize, Clone)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServedTarget {
    /// A resource we serve.
    Resource {
        resource: gateway::ResourceDescription,
    },
    /// This device itself, through a device pool, limited by the pool's filters.
    Device {
        pool_id: ResourceId,
        #[serde_as(as = "VecSkipError<_, WarnOnInvalidFilter>")]
        #[serde(default)]
        filters: Vec<Filter>,
    },
}

/// What we may reach through a peer.
#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GrantedTarget {
    /// A resource the peer serves for `site_id`.
    Resource {
        resource_id: ResourceId,
        site_id: SiteId,
    },
    /// The peer itself, through a device pool.
    Device { pool_id: ResourceId },
}

/// The portal asks us to accept a connection from `peer` so it can reach `target`.
#[serde_as]
#[derive(Debug, Deserialize, Clone)]
pub struct AuthorizePeer {
    #[serde(rename = "ref")]
    pub reference: AuthorizationRef,
    pub peer: Peer,
    pub target: ServedTarget,
    pub local_ice_credentials: IceCredentials,
    pub remote_ice_credentials: IceCredentials,
    pub connection: Connection,
    #[serde_as(as = "Option<DurationSeconds<u64>>")]
    #[serde(default)]
    pub expires_at: Option<Duration>,
    /// The responder's ingest token for the flow logs of this authorization.
    pub flow_logs_ingest_token: IngestToken,
}

/// The portal grants us access to `target` through `peer`.
#[derive(Debug, Deserialize, Clone)]
pub struct AccessGranted {
    pub peer: Peer,
    pub target: GrantedTarget,
    pub local_ice_credentials: IceCredentials,
    pub remote_ice_credentials: IceCredentials,
    pub connection: Connection,
    /// The initiator's ingest token for the flow logs of this authorization.
    pub flow_logs_ingest_token: IngestToken,
}

/// The portal refuses access we asked for.
#[derive(Debug, Deserialize, Clone)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AccessDenied {
    /// To a resource.
    Resource {
        resource_id: ResourceId,
        reason: FailReason,
        #[serde(default)]
        violated_properties: Vec<ViolatedProperty>,
    },
    /// To the device at these tunnel addresses.
    Device {
        #[serde(default)]
        ipv4: Option<Ipv4Addr>,
        #[serde(default)]
        ipv6: Option<Ipv6Addr>,
        reason: FailReason,
    },
}

/// An authorization of `device_id` to reach `resource_id` through us was revoked.
#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
pub struct RevokeAccess {
    pub device_id: DeviceId,
    pub resource_id: ResourceId,
}

/// A peer we hold an authorization with reconnected with a new public key.
#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
pub struct PublicKeyChanged {
    pub device_id: DeviceId,
    pub public_key: Key,
}

/// Our ICE candidates could not be delivered to `device_id`.
#[derive(Debug, Deserialize, Clone)]
pub struct IceCandidatesUndeliverable {
    pub device_id: DeviceId,
    pub reason: FailReason,
}

/// ICE candidates from one peer.
#[serde_as]
#[derive(Debug, Deserialize, PartialEq)]
pub struct IceCandidates {
    pub device_id: DeviceId,
    #[serde_as(as = "VecSkipError<_>")]
    pub candidates: Vec<IceCandidate>,
}

/// ICE candidates for several peers at once.
#[derive(Debug, Serialize, PartialEq, Clone)]
pub struct BroadcastIceCandidates {
    pub device_ids: Vec<DeviceId>,
    pub candidates: BTreeSet<IceCandidate>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
pub enum IngressMessages {
    Init(Init),
    ConfigChanged(ConfigUpdate),
    RelaysPresence(RelaysPresence),

    ResourceCreatedOrUpdated(ResourceDescription),
    ResourceDeleted(ResourceId),
    ResourceFiltersUpdated(ResourceFiltersUpdated),

    ServedSitesChanged(ServedSites),
    ServedResourceCreatedOrUpdated(gateway::ResourceDescription),
    ServedResourceDeleted(ResourceId),

    AuthorizePeer(AuthorizePeer),
    AccessGranted(AccessGranted),
    AccessDenied(AccessDenied),
    RevokeAccess(RevokeAccess),
    PublicKeyChanged(PublicKeyChanged),

    IceCandidates(IceCandidates),
    InvalidateIceCandidates(IceCandidates),
    IceCandidatesUndeliverable(IceCandidatesUndeliverable),

    DeviceDomainResolved(DeviceDomainResolved),
    DeviceDomainResolutionFailed(DeviceDomainResolutionFailed),
    DeviceDomainBrowsed(DeviceDomainBrowsed),
    DeviceDomainBrowseFailed(DeviceDomainBrowseFailed),
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
pub enum EgressMessages {
    /// Asks for access through the named resources, most preferred first.
    ///
    /// A packet for a device names every pool whose filters permit it and carries the
    /// device's tunnel address.
    RequestAccess {
        resource_ids: Vec<ResourceId>,
        #[serde(skip_serializing_if = "Option::is_none")]
        device_ip: Option<IpAddr>,
        /// The peers we are connected to, which the portal prefers.
        connected_device_ids: Vec<DeviceId>,
    },
    /// Confirms an [`AuthorizePeer`] was installed.
    PeerAuthorized {
        #[serde(rename = "ref")]
        reference: AuthorizationRef,
    },
    BroadcastIceCandidates(BroadcastIceCandidates),
    BroadcastInvalidatedIceCandidates(BroadcastIceCandidates),
    NoRelays {
        excluded_relay_ids: Vec<RelayId>,
    },
    ResolveDeviceDomain {
        domain: String,
    },
    BrowseDeviceDomain {
        domain: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

    #[test]
    fn parses_authorize_peer_for_a_served_resource() {
        let msg = ingress(&format!(
            r#"{{
                "event": "authorize_peer",
                "payload": {{
                    "ref": "signed",
                    "peer": {},
                    "target": {{
                        "type": "resource",
                        "resource": {{"type": "internet", "id": "00000000-0000-0000-0000-000000000003"}}
                    }},
                    "local_ice_credentials": {{"username": "a", "password": "b"}},
                    "remote_ice_credentials": {{"username": "c", "password": "d"}},
                    "connection": {{"type": "ice", "role": "controlled"}},
                    "expires_at": 1700000000,
                    "flow_logs_ingest_token": "{}"
                }}
            }}"#,
            peer_json(),
            flow_tracker::TEST_INGEST_TOKEN
        ));

        let IngressMessages::AuthorizePeer(authorize) = msg else {
            panic!("Expected `authorize_peer`, got {msg:?}");
        };

        assert!(matches!(
            authorize.target,
            ServedTarget::Resource {
                resource: gateway::ResourceDescription::Internet(_)
            }
        ));
        assert_eq!(
            authorize.connection,
            Connection::Ice {
                role: IceRole::Controlled
            }
        );
        assert_eq!(authorize.expires_at, Some(Duration::from_secs(1700000000)));
    }

    #[test]
    fn parses_authorize_peer_for_this_device() {
        let msg = ingress(&format!(
            r#"{{
                "event": "authorize_peer",
                "payload": {{
                    "ref": "signed",
                    "peer": {},
                    "target": {{
                        "type": "device",
                        "pool_id": "00000000-0000-0000-0000-000000000001",
                        "filters": [{{"protocol": "udp", "port_range_start": 53, "port_range_end": 53}}]
                    }},
                    "local_ice_credentials": {{"username": "a", "password": "b"}},
                    "remote_ice_credentials": {{"username": "c", "password": "d"}},
                    "connection": {{"type": "frostlink"}},
                    "flow_logs_ingest_token": "{}"
                }}
            }}"#,
            peer_json(),
            flow_tracker::TEST_INGEST_TOKEN
        ));

        let IngressMessages::AuthorizePeer(authorize) = msg else {
            panic!("Expected `authorize_peer`, got {msg:?}");
        };

        assert!(
            matches!(&authorize.target, ServedTarget::Device { filters, .. } if filters.len() == 1)
        );
        assert_eq!(authorize.connection, Connection::Frostlink);
        assert_eq!(authorize.expires_at, None);
    }

    #[test]
    fn parses_access_granted_through_a_resource() {
        let msg = ingress(&format!(
            r#"{{
                "event": "access_granted",
                "payload": {{
                    "peer": {},
                    "target": {{
                        "type": "resource",
                        "resource_id": "00000000-0000-0000-0000-000000000003",
                        "site_id": "00000000-0000-0000-0000-000000000004"
                    }},
                    "local_ice_credentials": {{"username": "a", "password": "b"}},
                    "remote_ice_credentials": {{"username": "c", "password": "d"}},
                    "connection": {{"type": "ice", "role": "controlling"}},
                    "flow_logs_ingest_token": "{}"
                }}
            }}"#,
            peer_json(),
            flow_tracker::TEST_INGEST_TOKEN
        ));

        let IngressMessages::AccessGranted(granted) = msg else {
            panic!("Expected `access_granted`, got {msg:?}");
        };

        assert!(matches!(granted.target, GrantedTarget::Resource { .. }));
    }

    #[test]
    fn parses_access_denied_for_a_device() {
        let msg = ingress(
            r#"{
                "event": "access_denied",
                "payload": {"type": "device", "ipv4": "100.64.0.2", "reason": "forbidden"}
            }"#,
        );

        assert!(matches!(
            msg,
            IngressMessages::AccessDenied(AccessDenied::Device {
                ipv4: Some(_),
                ipv6: None,
                reason: FailReason::Forbidden,
            })
        ));
    }

    #[test]
    fn ignores_unknown_fields() {
        let msg = ingress(
            r#"{
                "event": "revoke_access",
                "payload": {
                    "device_id": "00000000-0000-0000-0000-000000000001",
                    "resource_id": "00000000-0000-0000-0000-000000000002",
                    "added_later": true
                }
            }"#,
        );

        assert!(matches!(msg, IngressMessages::RevokeAccess(_)));
    }

    #[test]
    fn serializes_peer_authorized() {
        let msg = EgressMessages::PeerAuthorized {
            reference: AuthorizationRef("signed".to_owned()),
        };

        assert_eq!(
            serde_json::to_string(&msg).unwrap(),
            r#"{"event":"peer_authorized","payload":{"ref":"signed"}}"#
        );
    }

    #[test]
    fn serializes_request_access_to_a_device() {
        let msg = EgressMessages::RequestAccess {
            resource_ids: vec![ResourceId::from_u128(1)],
            device_ip: Some(IpAddr::V4(Ipv4Addr::new(100, 64, 0, 2))),
            connected_device_ids: vec![],
        };

        assert_eq!(
            serde_json::to_string(&msg).unwrap(),
            r#"{"event":"request_access","payload":{"resource_ids":["00000000-0000-0000-0000-000000000001"],"device_ip":"100.64.0.2","connected_device_ids":[]}}"#
        );
    }

    fn ingress(json: &str) -> IngressMessages {
        serde_json::from_str(json).unwrap()
    }

    fn peer_json() -> String {
        format!(
            r#"{{"id": "00000000-0000-0000-0000-000000000002", "name": "Phone", "slug": "phone", "public_key": "{KEY}", "preshared_key": "{KEY}", "ipv4": "100.64.0.2", "ipv6": "fd00:2021:1111::2"}}"#
        )
    }
}
