use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::net::IpAddr;

/// A platform-specific, stable identifier of an application.
///
/// - Apple: the code-signing identifier (the bundle ID for normally signed apps).
/// - Android: the package name.
/// - Windows: the absolute path of the executable.
/// - Linux: the absolute path of the executable.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct AppId(String);

impl AppId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<&str> for AppId {
    fn from(value: &str) -> Self {
        Self(value.trim().to_owned())
    }
}

impl From<String> for AppId {
    fn from(value: String) -> Self {
        Self::from(value.as_str())
    }
}

/// What the platform could learn about the application behind a flow.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AppIdentity {
    Known(AppId),
    /// The platform exposes no identity for this flow, for example a system daemon on iOS.
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    Allow,
    Deny,
}

/// The set of applications that may send traffic into the tunnel.
///
/// An absent list means the filter is off and every application may use the tunnel.
/// An empty list is a valid policy that denies every application.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Policy {
    allowed_apps: Option<BTreeSet<AppId>>,
}

impl Policy {
    pub fn off() -> Self {
        Self { allowed_apps: None }
    }

    pub fn allow_only(apps: impl IntoIterator<Item = AppId>) -> Self {
        Self {
            allowed_apps: Some(apps.into_iter().collect()),
        }
    }

    /// Parses the comma-separated form used by every MDM channel (`allowedApplications`).
    ///
    /// A value without any entry means "filter off", matching how the other MDM keys treat an unset value.
    pub fn from_mdm_value(value: Option<&str>) -> Self {
        let apps = value
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|app| !app.is_empty())
            .map(AppId::from)
            .collect::<BTreeSet<_>>();

        if apps.is_empty() {
            return Self::off();
        }

        Self {
            allowed_apps: Some(apps),
        }
    }

    pub fn is_enforcing(&self) -> bool {
        self.allowed_apps.is_some()
    }

    pub fn allowed_apps(&self) -> impl Iterator<Item = &AppId> {
        self.allowed_apps.iter().flatten()
    }

    pub fn allows(&self, app: &AppIdentity) -> bool {
        let Some(allowed) = &self.allowed_apps else {
            return true;
        };

        match app {
            AppIdentity::Known(id) => allowed.contains(id),
            AppIdentity::Unknown => false,
        }
    }
}

/// The destinations the filter guards: everything the tunnel routes, except its DNS servers.
#[derive(Clone, Debug)]
pub struct ProtectedDestinations {
    routes: IpNetworkTable<()>,
    exempt: BTreeSet<IpAddr>,
}

impl Default for ProtectedDestinations {
    fn default() -> Self {
        Self::new([], [])
    }
}

impl ProtectedDestinations {
    pub fn new(
        routes: impl IntoIterator<Item = IpNetwork>,
        dns_servers: impl IntoIterator<Item = IpAddr>,
    ) -> Self {
        let mut table = IpNetworkTable::new();
        for route in routes {
            table.insert(route, ());
        }

        Self {
            routes: table,
            exempt: dns_servers.into_iter().collect(),
        }
    }

    pub fn contains(&self, dst: IpAddr) -> bool {
        if self.exempt.contains(&dst) {
            return false;
        }

        self.routes.longest_match(dst).is_some()
    }

    pub fn routes(&self) -> impl Iterator<Item = IpNetwork> + '_ {
        self.routes.iter().map(|(network, ())| network)
    }

    pub fn exempt(&self) -> impl Iterator<Item = IpAddr> + '_ {
        self.exempt.iter().copied()
    }
}

/// Reference decision logic shared by all platform enforcers.
#[derive(Clone, Debug, Default)]
pub struct Filter {
    policy: Policy,
    destinations: ProtectedDestinations,
}

impl Filter {
    pub fn new(policy: Policy, destinations: ProtectedDestinations) -> Self {
        Self {
            policy,
            destinations,
        }
    }

    pub fn policy(&self) -> &Policy {
        &self.policy
    }

    pub fn destinations(&self) -> &ProtectedDestinations {
        &self.destinations
    }

    pub fn set_destinations(&mut self, destinations: ProtectedDestinations) {
        self.destinations = destinations;
    }

    pub fn decide(&self, app: &AppIdentity, dst: IpAddr) -> Verdict {
        if !self.destinations.contains(dst) {
            return Verdict::Allow;
        }

        if self.policy.allows(app) {
            return Verdict::Allow;
        }

        Verdict::Deny
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    #[test]
    fn unset_policy_allows_everything() {
        let filter = Filter::new(Policy::from_mdm_value(None), destinations());

        assert_eq!(
            filter.decide(&AppIdentity::Unknown, resource_ip()),
            Verdict::Allow
        );
    }

    #[test]
    fn value_without_entries_is_off() {
        assert_eq!(Policy::from_mdm_value(Some("  ")), Policy::off());
        assert_eq!(Policy::from_mdm_value(Some(" , ")), Policy::off());
    }

    #[test]
    fn listed_app_may_reach_protected_destination() {
        let filter = Filter::new(policy(), destinations());

        assert_eq!(
            filter.decide(
                &AppIdentity::Known(AppId::from("com.example.approved")),
                resource_ip()
            ),
            Verdict::Allow
        );
    }

    #[test]
    fn unlisted_app_is_denied_on_protected_destination() {
        let filter = Filter::new(policy(), destinations());

        assert_eq!(
            filter.decide(
                &AppIdentity::Known(AppId::from("com.example.other")),
                resource_ip()
            ),
            Verdict::Deny
        );
    }

    #[test]
    fn unknown_identity_is_denied_not_approved() {
        let filter = Filter::new(policy(), destinations());

        assert_eq!(
            filter.decide(&AppIdentity::Unknown, resource_ip()),
            Verdict::Deny
        );
    }

    #[test]
    fn unlisted_app_keeps_ordinary_internet_access() {
        let filter = Filter::new(policy(), destinations());

        assert_eq!(
            filter.decide(
                &AppIdentity::Known(AppId::from("com.example.other")),
                IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1))
            ),
            Verdict::Allow
        );
    }

    #[test]
    fn tunnel_dns_servers_are_exempt() {
        let filter = Filter::new(policy(), destinations());

        assert_eq!(
            filter.decide(&AppIdentity::Unknown, dns_server()),
            Verdict::Allow
        );
    }

    #[test]
    fn full_tunnel_protects_internet_destinations() {
        let filter = Filter::new(
            policy(),
            ProtectedDestinations::new(["0.0.0.0/0".parse().unwrap()], []),
        );

        assert_eq!(
            filter.decide(
                &AppIdentity::Known(AppId::from("com.example.other")),
                IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1))
            ),
            Verdict::Deny
        );
    }

    #[test]
    fn mdm_value_is_trimmed_and_split() {
        let policy = Policy::from_mdm_value(Some(" com.a , com.b,,"));

        assert_eq!(
            policy.allowed_apps().collect::<Vec<_>>(),
            vec![&AppId::from("com.a"), &AppId::from("com.b")]
        );
    }

    fn policy() -> Policy {
        Policy::from_mdm_value(Some("com.example.approved"))
    }

    fn destinations() -> ProtectedDestinations {
        ProtectedDestinations::new(
            [
                "100.96.0.0/11".parse().unwrap(),
                "10.0.0.0/8".parse().unwrap(),
            ],
            [dns_server()],
        )
    }

    fn resource_ip() -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(100, 96, 0, 1))
    }

    fn dns_server() -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(100, 100, 111, 1))
    }
}
