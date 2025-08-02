use std::{collections::BTreeSet, net::IpAddr};

use anyhow::{Context, Result};
use connlib_model::ResourceId;
use dns_types::DomainName;
use firezone_tunnel::DnsResourceRecord;
use serde::{Deserialize, Serialize};

pub fn serialize(records: BTreeSet<DnsResourceRecord>) -> Result<String> {
    let list = records
        .into_iter()
        .map(|r| Format {
            domain: r.domain,
            resource: r.resource,
            ips: r.ips,
        })
        .collect::<Vec<_>>();

    serde_json::to_string(&list).context("Failed to serialize DNS resource records")
}

pub fn deserialize(json: &str) -> Result<BTreeSet<DnsResourceRecord>> {
    let list = serde_json::from_str::<Vec<Format>>(json)
        .context("Failed to deserialize DNS resource records")?;

    let records = list
        .into_iter()
        .map(|f| DnsResourceRecord {
            domain: f.domain,
            resource: f.resource,
            ips: f.ips,
        })
        .collect();

    Ok(records)
}

// Stable format class for serializing/deserializing.
#[derive(Serialize, Deserialize)]
struct Format {
    domain: DomainName,
    resource: ResourceId,
    ips: Vec<IpAddr>,
}
