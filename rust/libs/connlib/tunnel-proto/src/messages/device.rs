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

    #[test]
    fn parses_init() {
        let msg = ingress(&init_json(INIT_FIELDS));

        let IngressMessages::Init(init) = msg else {
            panic!("Expected `init`, got {msg:?}");
        };

        assert_eq!(init.account_slug, "acme");
        assert_eq!(init.actor_name, "Jane Doe");
        assert_eq!(init.flow_logs.api_url, "https://flow-api.firezone.dev");
        assert!(init.flow_logs.upload_enabled());
        assert_eq!(init.resources.len(), 2);
        assert_eq!(init.served_sites.len(), 1);
        assert_eq!(init.served_resources.len(), 1);
        assert_eq!(init.authorizations.len(), 1);
    }

    #[test_case::test_case("account_slug"; "account slug")]
    #[test_case::test_case("actor_name"; "actor name")]
    #[test_case::test_case("flow_logs"; "flow logs config")]
    fn init_requires(field: &str) {
        let mut init = serde_json::from_str::<serde_json::Value>(&init_json(INIT_FIELDS)).unwrap();
        init["payload"].as_object_mut().unwrap().remove(field);

        serde_json::from_value::<IngressMessages>(init).unwrap_err();
    }

    #[test]
    fn init_skips_resources_it_cannot_parse() {
        let msg = ingress(&init_json(
            r#""resources": [
                {"address_foobar": "172.172.0.0/16", "id": "73037362-715d-4a83-a749-f18eadd970e6", "type": "cidr"},
                {"type": "what_is_this"}
            ],"#,
        ));

        assert!(matches!(msg, IngressMessages::Init(_)));
    }

    #[test]
    fn parses_config_changed() {
        let msg = ingress(
            r#"{
                "event": "config_changed",
                "payload": {"interface": {"ipv4": "100.67.138.25", "ipv6": "fd00:2021:1111::e:65ea"}}
            }"#,
        );

        assert!(matches!(msg, IngressMessages::ConfigChanged(_)));
    }

    #[test]
    fn parses_relays_presence() {
        let msg = ingress(
            r#"{
                "event": "relays_presence",
                "payload": {
                    "disconnected_ids": ["e95f9517-2152-4677-a16a-fbb2687050a3"],
                    "connected": [{
                        "id": "0a133356-7a9e-4b9a-b413-0d95a5720fd8",
                        "type": "turn",
                        "username": "1719367575:ZQHcVGkdnfgGmcP1",
                        "password": "ZWYiBeFHOJyYq0mcwAXjRpcuXIJJpzWlOXVdxwttrWg",
                        "addr": "172.28.0.101:3478",
                        "expires_at": 1719367575
                    }]
                }
            }"#,
        );

        assert!(matches!(msg, IngressMessages::RelaysPresence(_)));
    }

    #[test]
    fn parses_ice_candidates_and_skips_the_ones_it_cannot_parse() {
        let msg = ingress(
            r#"{
                "event": "ice_candidates",
                "payload": {
                    "device_id": "f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3",
                    "candidates": ["foo", "candidate:fffeff6435be70ddbf995982 1 udp 1694498559 87.121.72.60 57114 typ srflx raddr 0.0.0.0 rport 0"]
                }
            }"#,
        );

        let IngressMessages::IceCandidates(candidates) = msg else {
            panic!("Expected `ice_candidates`, got {msg:?}");
        };

        assert_eq!(candidates.candidates.len(), 1);
    }

    #[test_case::test_case("offline", FailReason::Offline; "known reason")]
    #[test_case::test_case("foobar", FailReason::Unknown; "unknown reason")]
    fn parses_access_denied_for_a_resource(reason: &str, expected: FailReason) {
        let msg = ingress(&format!(
            r#"{{
                "event": "access_denied",
                "payload": {{"type": "resource", "resource_id": "f16ecfa0-a94f-4bfd-a2ef-1cc1f2ef3da3", "reason": "{reason}"}}
            }}"#
        ));

        let IngressMessages::AccessDenied(AccessDenied::Resource { reason, .. }) = msg else {
            panic!("Expected `access_denied` for a resource, got {msg:?}");
        };

        assert_eq!(
            std::mem::discriminant(&reason),
            std::mem::discriminant(&expected)
        );
    }

    #[test]
    fn parses_public_key_changed() {
        let msg = ingress(&format!(
            r#"{{
                "event": "public_key_changed",
                "payload": {{"device_id": "a3632404-4b03-4468-9fc0-4a4c82415ade", "public_key": "{KEY}"}}
            }}"#
        ));

        assert!(matches!(msg, IngressMessages::PublicKeyChanged(_)));
    }

    #[test]
    fn parses_ice_candidates_undeliverable() {
        let msg = ingress(
            r#"{
                "event": "ice_candidates_undeliverable",
                "payload": {"device_id": "a3632404-4b03-4468-9fc0-4a4c82415ade", "reason": "offline"}
            }"#,
        );

        assert!(matches!(
            msg,
            IngressMessages::IceCandidatesUndeliverable(IceCandidatesUndeliverable {
                reason: FailReason::Offline,
                ..
            })
        ));
    }

    #[test]
    fn parses_device_domain_answers() {
        let resolved = ingress(
            r#"{
                "event": "device_domain_resolved",
                "payload": {"domain": "device-42.firezone.network", "ipv4": "100.64.0.42", "ipv6": "fd00:2021:1111::42"}
            }"#,
        );
        let failed = ingress(
            r#"{
                "event": "device_domain_resolution_failed",
                "payload": {"domain": "your-devices.firezone.network", "reason": "not_a_device"}
            }"#,
        );
        let browsed = ingress(
            r#"{
                "event": "device_domain_browsed",
                "payload": {"domain": "your-devices.firezone.network", "names": ["alice-laptop.firezone.network"], "ttl": 30, "total": 5}
            }"#,
        );
        let browse_failed = ingress(
            r#"{
                "event": "device_domain_browse_failed",
                "payload": {"domain": "ghost.firezone.network", "reason": "not_found"}
            }"#,
        );

        assert!(matches!(resolved, IngressMessages::DeviceDomainResolved(_)));
        assert!(matches!(
            failed,
            IngressMessages::DeviceDomainResolutionFailed(DeviceDomainResolutionFailed {
                reason: FailReason::NotADevice,
                ..
            })
        ));
        assert!(matches!(
            browsed,
            IngressMessages::DeviceDomainBrowsed(DeviceDomainBrowsed { total: 5, .. })
        ));
        assert!(matches!(
            browse_failed,
            IngressMessages::DeviceDomainBrowseFailed(DeviceDomainBrowseFailed {
                reason: FailReason::NotFound,
                ..
            })
        ));
    }

    #[test]
    fn serializes_request_access_to_resources() {
        let msg = EgressMessages::RequestAccess {
            resource_ids: vec![ResourceId::from_u128(1)],
            device_ip: None,
            connected_device_ids: vec![DeviceId::from_u128(2)],
        };

        assert_eq!(
            serde_json::to_string(&msg).unwrap(),
            r#"{"event":"request_access","payload":{"resource_ids":["00000000-0000-0000-0000-000000000001"],"connected_device_ids":["00000000-0000-0000-0000-000000000002"]}}"#
        );
    }

    #[test]
    fn serializes_device_domain_queries() {
        let resolve = EgressMessages::ResolveDeviceDomain {
            domain: "device-42.firezone.network".to_owned(),
        };
        let browse = EgressMessages::BrowseDeviceDomain {
            domain: "firezone.network".to_owned(),
        };

        assert_eq!(
            serde_json::to_string(&resolve).unwrap(),
            r#"{"event":"resolve_device_domain","payload":{"domain":"device-42.firezone.network"}}"#
        );
        assert_eq!(
            serde_json::to_string(&browse).unwrap(),
            r#"{"event":"browse_device_domain","payload":{"domain":"firezone.network"}}"#
        );
    }

    #[test]
    fn serializes_no_relays() {
        let msg = EgressMessages::NoRelays {
            excluded_relay_ids: vec![RelayId::from_u128(1)],
        };

        assert_eq!(
            serde_json::to_string(&msg).unwrap(),
            r#"{"event":"no_relays","payload":{"excluded_relay_ids":["00000000-0000-0000-0000-000000000001"]}}"#
        );
    }

    const INIT_FIELDS: &str = r#""resources": [
            {"type": "cidr", "id": "73037362-715d-4a83-a749-f18eadd970e6", "name": "172.172.0.0/16", "address": "172.172.0.0/16", "sites": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}]},
            {"type": "dns", "id": "03000143-e25e-45c7-aafb-144990e57dcd", "name": "gitlab.mycorp.com", "address": "gitlab.mycorp.com", "sites": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}]}
        ],
        "served_sites": [{"name": "Internet", "id": "eb94482a-94f4-47cb-8127-14fb3afa5516"}],
        "served_resources": [{"type": "internet", "id": "1106047c-cd5d-4151-b679-96b93da7383b"}],
        "authorizations": [{"device_id": "a3632404-4b03-4468-9fc0-4a4c82415ade", "resource_id": "1106047c-cd5d-4151-b679-96b93da7383b", "expires_at": 1729813989}],"#;

    fn init_json(fields: &str) -> String {
        format!(
            r#"{{
                "event": "init",
                "payload": {{
                    "interface": {{"ipv4": "100.64.0.1", "ipv6": "fd00:2021:1111::1"}},
                    {fields}
                    "account_slug": "acme",
                    "actor_name": "Jane Doe",
                    "flow_logs": {{"api_url": "https://flow-api.firezone.dev", "upload_interval_secs": 60, "upload_batch_size": 1000}}
                }}
            }}"#
        )
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
