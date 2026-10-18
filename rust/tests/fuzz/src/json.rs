//! Writes replayed tunnel-proto inputs as JSON Lines, one file per entity, for querying the corpus.
#![cfg_attr(coverage_nightly, coverage(off))]

use std::{
    collections::BTreeMap,
    fs::File,
    io::{BufWriter, Write as _},
    net::SocketAddr,
    panic::AssertUnwindSafe,
    path::{Path, PathBuf},
};

use anyhow::Context as _;
use connlib_model::{ClientId, GatewayId, ResourceId, SiteId};
use dns_types::{DoHUrl, DomainName};
use serde::{Serialize, Serializer, ser::SerializeMap as _};
use serde_json::{Map, Value};
use tunnel_proto::{
    MaliciousBehaviour, dns,
    messages::{Filter, PortRange},
};

use crate::{
    probe::{ExpectedProbe, ProbeRequest},
    reference::ReferenceState,
    resource::Resource,
    stub_portal::StubPortal,
    transition::{Destination, DnsQuery, Transition},
};

/// Receives the states and transitions of one tunnel-proto input as it runs.
pub trait Observer {
    fn start(&mut self, _portal: &StubPortal, _reference: &ReferenceState) {}

    /// Called before `transition` is applied to `reference`.
    fn transition(&mut self, _step: usize, _transition: &Transition, _reference: &ReferenceState) {}

    /// Called once `reference` reflects the transition at `step`.
    fn applied(&mut self, _step: usize, _reference: &ReferenceState) {}
}

impl Observer for () {}

/// Runs each input with `run` and writes what it observes into `directory`.
pub fn emit(
    inputs: &[(PathBuf, Vec<u8>)],
    directory: &Path,
    run: fn(&[u8], &mut Emitter),
) -> anyhow::Result<()> {
    let mut emitter = Emitter::new(directory)?;
    for (path, data) in inputs {
        let name = path
            .file_name()
            .with_context(|| format!("{} has no file name", path.display()))?;
        emitter.begin(name.to_string_lossy().into_owned(), data.len());
        if let Err(panic) = std::panic::catch_unwind(AssertUnwindSafe(|| run(data, &mut emitter))) {
            eprintln!("Replay failed for {}", path.display());
            std::panic::resume_unwind(panic);
        }
        emitter.end();
    }
    emitter.finish()?;

    Ok(())
}

/// Writes one JSON Lines file per entity into a directory.
///
/// Every row carries the name of the corpus input it belongs to; IDs are only unique within an input.
pub struct Emitter {
    files: BTreeMap<&'static str, BufWriter<File>>,
    input: String,
    summary: Option<Input>,
}

impl Emitter {
    const FILES: [&str; 10] = [
        "inputs",
        "sites",
        "resources",
        "clients",
        "gateways",
        "relays",
        "dns_records",
        "transitions",
        "dns_queries",
        "probes",
    ];

    fn new(directory: &Path) -> anyhow::Result<Self> {
        std::fs::create_dir_all(directory)
            .with_context(|| format!("failed to create {}", directory.display()))?;
        let files = Self::FILES
            .into_iter()
            .map(|name| {
                let path = directory.join(format!("{name}.jsonl"));
                let file = File::create(&path)
                    .with_context(|| format!("failed to create {}", path.display()))?;

                Ok((name, BufWriter::new(file)))
            })
            .collect::<anyhow::Result<_>>()?;

        Ok(Self {
            files,
            input: String::new(),
            summary: None,
        })
    }

    /// Starts the rows of the corpus input named `input`, which has `size` bytes.
    fn begin(&mut self, input: String, size: usize) {
        self.input = input;
        self.summary = Some(Input {
            size,
            transitions: 0,
            iceless: false,
            search_domain: None,
        });
    }

    /// Ends the rows of the current input.
    fn end(&mut self) {
        let summary = self.summary.take().expect("an input has begun");
        self.write("inputs", summary);
    }

    fn finish(&mut self) -> anyhow::Result<()> {
        for file in self.files.values_mut() {
            file.flush()?;
        }

        Ok(())
    }

    fn write(&mut self, file: &'static str, row: impl Serialize) {
        let mut row = serde_json::to_value(row).expect("rows serialize to JSON");
        let Value::Object(fields) = &mut row else {
            panic!("rows are JSON objects");
        };
        fields.insert("input".to_owned(), Value::String(self.input.clone()));

        let writer = self.files.get_mut(file).expect("all files are open");
        serde_json::to_writer(&mut *writer, &row).expect("failed to write row");
        writer.write_all(b"\n").expect("failed to write row");
    }
}

impl Observer for Emitter {
    fn start(&mut self, portal: &StubPortal, reference: &ReferenceState) {
        let resources = portal.all_resources();

        let sites = portal
            .regular_sites()
            .iter()
            .chain(resources.iter().flat_map(Resource::sites))
            .map(|site| (site.id, site))
            .collect::<BTreeMap<_, _>>();
        for site in sites.values() {
            self.write("sites", site);
        }
        for resource in &resources {
            self.write("resources", resource);
        }

        for (id, client) in &reference.clients {
            self.write("clients", node(id, client));
        }
        let site_by_gateway = portal
            .gateway_tunnel_ips()
            .map(|(gateway, _, _, site)| (gateway, site))
            .collect::<BTreeMap<GatewayId, SiteId>>();
        for (id, gateway) in &reference.gateways {
            let mut row = node(id, gateway);
            row.insert("site_id".to_owned(), json(site_by_gateway.get(id)));
            self.write("gateways", row);
        }
        for (id, relay) in &reference.relays {
            self.write("relays", node(id, relay));
        }

        let Value::Object(records) = json(&reference.global_dns_records) else {
            panic!("DNS records serialize to a map");
        };
        for (domain, records) in records {
            self.write(
                "dns_records",
                serde_json::json!({ "domain": domain, "records": records }),
            );
        }

        let summary = self.summary.as_mut().expect("an input has begun");
        summary.iceless = portal.iceless();
        summary.search_domain = portal.search_domain();
    }

    fn transition(&mut self, step: usize, transition: &Transition, reference: &ReferenceState) {
        self.summary
            .as_mut()
            .expect("an input has begun")
            .transitions = step + 1;
        self.write(
            "transitions",
            Step {
                step,
                row: transition,
            },
        );

        let Transition::SendDnsQueries(queries) = transition else {
            return;
        };
        for (client_id, query) in queries {
            let dns_resources = matching_dns_resources(reference, *client_id, &query.domain);
            self.write(
                "dns_queries",
                Step {
                    step,
                    row: DnsQueryRow {
                        client_id: *client_id,
                        query,
                        dns_resources,
                    },
                },
            );
        }
    }

    fn applied(&mut self, step: usize, reference: &ReferenceState) {
        for probe in reference.expected_probes.values() {
            let dns_resources = probe_domain(&probe.request)
                .map(|domain| matching_dns_resources(reference, probe.origin, domain));
            self.write(
                "probes",
                Step {
                    step,
                    row: ProbeRow {
                        probe,
                        dns_resources,
                    },
                },
            );
        }
    }
}

#[derive(Serialize)]
struct Input {
    size: usize,
    transitions: usize,
    iceless: bool,
    search_domain: Option<DomainName>,
}

#[derive(Serialize)]
struct Step<T> {
    step: usize,
    #[serde(flatten)]
    row: T,
}

#[derive(Serialize)]
struct DnsQueryRow<'a> {
    client_id: ClientId,
    #[serde(flatten)]
    query: &'a DnsQuery,
    dns_resources: Vec<ResourceId>,
}

#[derive(Serialize)]
struct ProbeRow<'a> {
    #[serde(flatten)]
    probe: &'a ExpectedProbe,
    dns_resources: Option<Vec<ResourceId>>,
}

/// Returns the client's DNS resources matching `domain`, in the order the reference model prefers them.
fn matching_dns_resources(
    reference: &ReferenceState,
    client: ClientId,
    domain: &DomainName,
) -> Vec<ResourceId> {
    reference.clients[&client]
        .inner()
        .dns_resources_by_domain(domain, |_| true, |_| true)
        .into_iter()
        .map(|resource| resource.id)
        .collect()
}

fn probe_domain(request: &ProbeRequest) -> Option<&DomainName> {
    let dst = match request {
        ProbeRequest::Icmp { dst, .. } => dst,
        ProbeRequest::Udp { dst, .. } => dst,
        ProbeRequest::Tcp { dst, .. } => dst,
    };

    match dst {
        Destination::DomainName { name, .. } => Some(name),
        Destination::IpAddr(_) => None,
    }
}

/// Returns a host's row: its ID, its network attachment and the fields of the node it runs.
fn node(id: &impl Serialize, host: &impl Serialize) -> Map<String, Value> {
    let Value::Object(mut row) = json(host) else {
        panic!("hosts serialize to a map");
    };
    if let Some(Value::Object(node)) = row.remove("inner") {
        row.extend(node);
    }
    row.insert("id".to_owned(), json(id));

    row
}

fn json(value: impl Serialize) -> Value {
    serde_json::to_value(value).expect("harness state serializes to JSON")
}

/// Serializes a newtype variant's payload under a `value` field, so it fits an internally tagged enum.
pub(crate) fn value<T, S>(value: &T, serializer: S) -> Result<S::Ok, S::Error>
where
    T: Serialize,
    S: Serializer,
{
    let mut map = serializer.serialize_map(Some(1))?;
    map.serialize_entry("value", value)?;
    map.end()
}

pub(crate) fn filters<S>(filters: &[Filter], serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    #[derive(Serialize)]
    struct Element(#[serde(with = "FilterDef")] Filter);

    serializer.collect_seq(filters.iter().cloned().map(Element))
}

#[derive(Serialize)]
#[serde(remote = "Filter", tag = "protocol", rename_all = "snake_case")]
enum FilterDef {
    Udp(#[serde(with = "PortRangeDef")] PortRange),
    Tcp(#[serde(with = "PortRangeDef")] PortRange),
    Icmp,
}

#[derive(Serialize)]
#[serde(remote = "PortRange")]
struct PortRangeDef {
    #[serde(getter = "PortRange::start")]
    start: u16,
    #[serde(getter = "PortRange::end")]
    end: u16,
}

#[derive(Serialize)]
#[serde(remote = "dns::Upstream", tag = "kind")]
pub(crate) enum UpstreamDef {
    Do53 { server: SocketAddr },
    DoH { server: DoHUrl },
}

#[derive(Serialize)]
#[serde(remote = "MaliciousBehaviour")]
pub(crate) struct MaliciousBehaviourDef {
    ignore_resource_filters: bool,
    send_untracked_icmp_errors: bool,
    ignore_no_authorization_events: bool,
}
