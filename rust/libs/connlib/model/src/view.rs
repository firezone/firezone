use core::fmt;
use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};
use std::borrow::Cow;
use std::fmt::Debug;

use crate::ResourceId;
use crate::Site;

#[derive(Debug, Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ResourceStatus {
    Unknown,
    Online,
    Offline,
}

impl fmt::Display for ResourceStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ResourceStatus::Unknown => write!(f, "unknown"),
            ResourceStatus::Online => write!(f, "online"),
            ResourceStatus::Offline => write!(f, "offline"),
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq, Hash)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResourceView {
    Dns(DnsResourceView),
    Cidr(CidrResourceView),
    Internet(InternetResourceView),
}

impl ResourceView {
    pub fn address_description(&self) -> Option<&str> {
        match self {
            ResourceView::Dns(r) => r.address_description.as_deref(),
            ResourceView::Cidr(r) => r.address_description.as_deref(),
            ResourceView::Internet(_) => None,
        }
    }

    pub fn name(&self) -> &str {
        match self {
            ResourceView::Dns(r) => &r.name,
            ResourceView::Cidr(r) => &r.name,
            ResourceView::Internet(r) => &r.name,
        }
    }

    pub fn status(&self) -> ResourceStatus {
        match self {
            ResourceView::Dns(r) => r.status,
            ResourceView::Cidr(r) => r.status,
            ResourceView::Internet(r) => r.status,
        }
    }

    pub fn id(&self) -> ResourceId {
        match self {
            ResourceView::Dns(r) => r.id,
            ResourceView::Cidr(r) => r.id,
            ResourceView::Internet(r) => r.id,
        }
    }

    /// What the GUI clients should paste to the clipboard, e.g. `https://github.com/firezone`
    pub fn pastable(&self) -> Cow<'_, str> {
        match self {
            ResourceView::Dns(r) => Cow::from(&r.address),
            ResourceView::Cidr(r) => Cow::from(r.address.to_string()),
            ResourceView::Internet(_) => Cow::default(),
        }
    }

    pub fn sites(&self) -> &[Site] {
        match self {
            ResourceView::Dns(r) => &r.sites,
            ResourceView::Cidr(r) => &r.sites,
            ResourceView::Internet(r) => &r.sites,
        }
    }

    pub fn is_internet_resource(&self) -> bool {
        matches!(self, ResourceView::Internet(_))
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq, Hash)]
pub struct DnsResourceView {
    /// Resource's id.
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub address: String,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub address_description: Option<String>,
    pub sites: Vec<Site>,

    pub status: ResourceStatus,
}

/// Description of a resource that maps to a CIDR.
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct CidrResourceView {
    /// Resource's id.
    pub id: ResourceId,
    /// CIDR that this resource points to.
    pub address: IpNetwork,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub address_description: Option<String>,
    pub sites: Vec<Site>,

    pub status: ResourceStatus,
}

/// Description of an Internet resource
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct InternetResourceView {
    /// Name for display always set to "Internet Resource"
    pub name: String,

    pub id: ResourceId,
    pub sites: Vec<Site>,

    pub status: ResourceStatus,
}

impl PartialOrd for ResourceView {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for ResourceView {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        if self.is_internet_resource() {
            return std::cmp::Ordering::Less;
        }

        if other.is_internet_resource() {
            return std::cmp::Ordering::Greater;
        }

        (self.name(), self.id()).cmp(&(other.name(), other.id()))
    }
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use itertools::Itertools;

    use super::{
        DnsResourceView, InternetResourceView, ResourceId, ResourceStatus, ResourceView, Site,
    };

    fn fake_resource(name: &str, uuid: &str) -> ResourceView {
        ResourceView::Dns(DnsResourceView {
            id: ResourceId::from_str(uuid).unwrap(),
            name: name.to_string(),
            address: "unused.example.com".to_string(),
            address_description: Some("test description".to_string()),
            sites: vec![Site {
                name: "test".to_string(),
                id: "99ba0c1e-5189-4cfc-a4db-fd6cb1c937fd".parse().unwrap(),
            }],
            status: ResourceStatus::Online,
        })
    }

    fn internet_resource(uuid: &str) -> ResourceView {
        ResourceView::Internet(InternetResourceView {
            name: "Internet Resource".to_string(),
            id: ResourceId::from_str(uuid).unwrap(),
            sites: vec![Site {
                name: "test".to_string(),
                id: "99ba0c1e-5189-4cfc-a4db-fd6cb1c937fd".parse().unwrap(),
            }],
            status: ResourceStatus::Offline,
        })
    }

    #[test]
    fn sort_resources_normal() {
        let cloudflare = fake_resource("Cloudflare DNS", "2efe9c25-bd92-49a0-99d7-8b92da014dd5");
        let example = fake_resource("Example", "613eaf56-6efa-45e5-88aa-ea4ad64d8c18");
        let fast = fake_resource("Fast.com", "624b7154-08f6-4c9e-bac0-c3a587fc9322");
        let metabase_1 = fake_resource("Metabase", "98ee1682-8192-4f15-b4a6-03178dfa7f95");
        let metabase_2 = fake_resource("Metabase", "e431d1b8-afc2-4f93-95c2-0d15413f5422");
        let ifconfig = fake_resource("ifconfig.net", "6b7188f5-00ac-41dc-9ddd-57e2384f31ef");
        let wildcard = fake_resource("*.test.net", "6b7188f5-00ac-41dc-9ddd-57e2384f31af");
        let ten = fake_resource("10", "9d1907cc-0693-4063-b388-4d29524e2514");
        let nine = fake_resource("9", "a7b66f28-9cd1-40fc-bdc4-4763ed92ea41");
        let emoji = fake_resource("🫠", "7d08cfca-8737-4c5e-a88e-e92574657217");
        let internet = internet_resource("cb13bca0-490a-4aae-a039-31a8f93e2281");

        let resource_descriptions = vec![
            nine.clone(),
            ten.clone(),
            fast.clone(),
            ifconfig.clone(),
            emoji.clone(),
            example.clone(),
            cloudflare.clone(),
            metabase_2.clone(),
            metabase_1.clone(),
            internet.clone(),
            wildcard.clone(),
        ];

        let expected = vec![
            internet,   // Internet resources are always first
            wildcard,   // Asterisk before numbers
            ten,        // Numbers before letters
            nine,       // Numbers are sorted lexicographically, not numerically
            cloudflare, // Then uppercase, in alphabetical order
            example,    // Then uppercase, in alphabetical order
            fast,       // Then uppercase, in alphabetical order
            metabase_1, // UUIDs tie-break if the names are identical
            metabase_2, // UUIDs tie-break if the names are identical
            ifconfig,   // Lowercase comes after all uppercase are done
            // Emojis start with a leading '1' bit, so they come after all
            // [Basic Latin](https://en.wikipedia.org/wiki/Basic_Latin_\(Unicode_block\)) chars
            emoji,
        ];

        assert_eq!(
            resource_descriptions.into_iter().sorted().collect_vec(),
            expected
        );
    }
}
