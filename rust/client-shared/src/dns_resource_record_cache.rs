use std::{collections::BTreeSet, net::IpAddr};

use anyhow::{Context, Result};
use connlib_model::ResourceId;
use dns_types::DomainName;
use firezone_bin_shared::known_dirs;
use firezone_tunnel::DnsResourceRecord;
use serde::{Deserialize, Serialize};

pub fn load() -> Result<BTreeSet<DnsResourceRecord>> {
    let path = known_dirs::dns_resource_records_cache()?;
    let json = std::fs::read_to_string(path).context("Failed to read file")?;

    let list = serde_json::from_str::<Vec<Format>>(&json)
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

pub fn save(records: BTreeSet<DnsResourceRecord>) -> Result<()> {
    let path = known_dirs::dns_resource_records_cache()?;

    let list = records
        .into_iter()
        .map(|r| Format {
            domain: r.domain,
            resource: r.resource,
            ips: r.ips,
        })
        .collect::<Vec<_>>();

    let json = serde_json::to_string(&list).context("Failed to serialize DNS resource records")?;

    std::fs::write(path, json).context("Failed to write JSON to disk")?;

    Ok(())
}

// Stable format class for serializing/deserializing.
#[derive(Serialize, Deserialize)]
struct Format {
    domain: DomainName,
    resource: ResourceId,
    ips: Vec<IpAddr>,
}
