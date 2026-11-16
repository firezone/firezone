//! Enforcement with cgroup eBPF programs, see `app-filter-ebpf` for the kernel side.
//!
//! The programs attach to the root cgroup in multi-program mode, so they coexist
//! with container runtimes and other tooling. Userspace owns the policy maps:
//! the listed executables, the tunnel routes and the exempt DNS servers. Process
//! tracking seeds from `/proc` once, after which the tracepoints keep it current.
//!
//! Identity is the executable path. It says which program opened the socket; it
//! does not vouch for the program's integrity.

use crate::{Interface, Policy, ProtectedDestinations};
use anyhow::Result;

#[cfg(feature = "ebpf")]
use crate::AppId;
#[cfg(feature = "ebpf")]
use anyhow::Context as _;
#[cfg(feature = "ebpf")]
use ip_network::IpNetwork;
#[cfg(feature = "ebpf")]
use std::net::IpAddr;

#[cfg(feature = "ebpf")]
pub struct Enforcer {
    ebpf: aya::Ebpf,
    protected_v4: Vec<aya::maps::lpm_trie::Key<[u8; 4]>>,
    protected_v6: Vec<aya::maps::lpm_trie::Key<[u8; 16]>>,
    exempt_v4: Vec<[u8; 4]>,
    exempt_v6: Vec<[u8; 16]>,
}

#[cfg(feature = "ebpf")]
impl Enforcer {
    pub fn new(policy: &Policy) -> Result<Self> {
        use app_filter_ebpf_shared::{ExePath, PRESENT};
        use aya::programs::{CgroupAttachMode, CgroupSockAddr, TracePoint};

        let mut ebpf = aya::EbpfLoader::new()
            .load(aya::include_bytes_aligned!(concat!(
                env!("OUT_DIR"),
                "/app-filter-ebpf-main"
            )))
            .context("Failed to load eBPF program")?;

        let exes = policy
            .allowed_apps()
            .filter_map(|app| {
                ExePath::from_bytes(app.as_str().as_bytes())
                    .or_else(|| {
                        tracing::warn!(app = app.as_str(), "Ignoring application: path too long");
                        None
                    })
                    .map(|exe| (app, exe))
            })
            .collect::<Vec<_>>();

        let mut allowed_exes = hash_map::<ExePath, u8>(&mut ebpf, "ALLOWED_EXES")?;
        for (_, exe) in &exes {
            allowed_exes.insert(exe, &PRESENT, 0)?;
        }

        let mut allowed_tgids = hash_map::<u32, u8>(&mut ebpf, "ALLOWED_TGIDS")?;
        // Our own sockets reach relays and Gateways through the physical interface, which a full-tunnel route also covers.
        allowed_tgids.insert(&std::process::id(), &PRESENT, 0)?;
        for tgid in running_processes(exes.iter().map(|(app, _)| *app)) {
            allowed_tgids.insert(&tgid, &PRESENT, 0)?;
        }

        for name in [
            "sched_process_exec",
            "sched_process_fork",
            "sched_process_exit",
        ] {
            let program: &mut TracePoint = ebpf
                .program_mut(name)
                .with_context(|| format!("No `{name}` program"))?
                .try_into()?;
            program.load()?;
            program
                .attach("sched", name)
                .with_context(|| format!("Failed to attach `{name}` tracepoint"))?;
        }

        let cgroup = std::fs::File::open(CGROUP_ROOT)
            .with_context(|| format!("Failed to open cgroup root {CGROUP_ROOT}"))?;
        for name in ["connect4", "connect6", "sendmsg4", "sendmsg6"] {
            let program: &mut CgroupSockAddr = ebpf
                .program_mut(name)
                .with_context(|| format!("No `{name}` program"))?
                .try_into()?;
            program.load()?;
            program
                .attach(&cgroup, CgroupAttachMode::AllowMultiple)
                .with_context(|| format!("Failed to attach `{name}` to {CGROUP_ROOT}"))?;
        }

        Ok(Self {
            ebpf,
            protected_v4: Vec::new(),
            protected_v6: Vec::new(),
            exempt_v4: Vec::new(),
            exempt_v6: Vec::new(),
        })
    }

    pub fn apply(&mut self, destinations: &ProtectedDestinations, _: &Interface) -> Result<()> {
        use app_filter_ebpf_shared::PRESENT;
        use aya::maps::lpm_trie::Key;

        self.clear();

        let (v4, v6) = destinations
            .routes()
            .partition::<Vec<_>, _>(|r| matches!(r, IpNetwork::V4(_)));
        self.protected_v4 = v4
            .into_iter()
            .filter_map(|r| match r {
                IpNetwork::V4(r) => Some(Key::new(
                    u32::from(r.netmask()),
                    r.network_address().octets(),
                )),
                IpNetwork::V6(_) => None,
            })
            .collect();
        self.protected_v6 = v6
            .into_iter()
            .filter_map(|r| match r {
                IpNetwork::V4(_) => None,
                IpNetwork::V6(r) => Some(Key::new(
                    u32::from(r.netmask()),
                    r.network_address().octets(),
                )),
            })
            .collect();
        self.exempt_v4 = destinations
            .exempt()
            .filter_map(|ip| match ip {
                IpAddr::V4(ip) => Some(ip.octets()),
                IpAddr::V6(_) => None,
            })
            .collect();
        self.exempt_v6 = destinations
            .exempt()
            .filter_map(|ip| match ip {
                IpAddr::V4(_) => None,
                IpAddr::V6(ip) => Some(ip.octets()),
            })
            .collect();

        let mut exempt_v4 = hash_map(&mut self.ebpf, "EXEMPT_V4")?;
        for ip in &self.exempt_v4 {
            exempt_v4.insert(ip, &PRESENT, 0)?;
        }
        let mut exempt_v6 = hash_map(&mut self.ebpf, "EXEMPT_V6")?;
        for ip in &self.exempt_v6 {
            exempt_v6.insert(ip, &PRESENT, 0)?;
        }
        let mut protected_v4 = lpm_trie(&mut self.ebpf, "PROTECTED_V4")?;
        for key in &self.protected_v4 {
            protected_v4.insert(key, &PRESENT, 0)?;
        }
        let mut protected_v6 = lpm_trie(&mut self.ebpf, "PROTECTED_V6")?;
        for key in &self.protected_v6 {
            protected_v6.insert(key, &PRESENT, 0)?;
        }

        tracing::debug!(
            num_routes = self.protected_v4.len() + self.protected_v6.len(),
            "Installed eBPF application filter"
        );

        Ok(())
    }

    pub fn clear(&mut self) {
        if let Err(e) = self.try_clear() {
            tracing::warn!("Failed to clear eBPF application filter: {e:#}");
        }
    }

    fn try_clear(&mut self) -> Result<()> {
        let mut protected_v4 = lpm_trie::<[u8; 4], u8>(&mut self.ebpf, "PROTECTED_V4")?;
        for key in self.protected_v4.drain(..) {
            protected_v4.remove(&key)?;
        }
        let mut protected_v6 = lpm_trie::<[u8; 16], u8>(&mut self.ebpf, "PROTECTED_V6")?;
        for key in self.protected_v6.drain(..) {
            protected_v6.remove(&key)?;
        }
        let mut exempt_v4 = hash_map::<[u8; 4], u8>(&mut self.ebpf, "EXEMPT_V4")?;
        for ip in self.exempt_v4.drain(..) {
            exempt_v4.remove(&ip)?;
        }
        let mut exempt_v6 = hash_map::<[u8; 16], u8>(&mut self.ebpf, "EXEMPT_V6")?;
        for ip in self.exempt_v6.drain(..) {
            exempt_v6.remove(&ip)?;
        }

        Ok(())
    }
}

#[cfg(feature = "ebpf")]
fn hash_map<'a, K: aya::Pod, V: aya::Pod>(
    ebpf: &'a mut aya::Ebpf,
    name: &str,
) -> Result<aya::maps::HashMap<&'a mut aya::maps::MapData, K, V>> {
    let map = ebpf
        .map_mut(name)
        .with_context(|| format!("No `{name}` map"))?;

    Ok(aya::maps::HashMap::try_from(map)?)
}

#[cfg(feature = "ebpf")]
fn lpm_trie<'a, K: aya::Pod, V: aya::Pod>(
    ebpf: &'a mut aya::Ebpf,
    name: &str,
) -> Result<aya::maps::LpmTrie<&'a mut aya::maps::MapData, K, V>> {
    let map = ebpf
        .map_mut(name)
        .with_context(|| format!("No `{name}` map"))?;

    Ok(aya::maps::LpmTrie::try_from(map)?)
}

#[cfg(feature = "ebpf")]
const CGROUP_ROOT: &str = "/sys/fs/cgroup";

/// Thread-group IDs of processes that currently run one of the listed executables.
#[cfg(feature = "ebpf")]
fn running_processes<'a>(apps: impl IntoIterator<Item = &'a AppId>) -> Vec<u32> {
    use std::path::PathBuf;

    let apps = apps
        .into_iter()
        .map(|app| PathBuf::from(app.as_str()))
        .collect::<std::collections::BTreeSet<_>>();

    let Ok(proc_dir) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };

    proc_dir
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let tgid = entry.file_name().to_str()?.parse::<u32>().ok()?;
            let exe = std::fs::read_link(entry.path().join("exe")).ok()?;

            apps.contains(&exe).then_some(tgid)
        })
        .collect()
}

/// Fails closed: a build without the eBPF program cannot honour a policy, so it must not bring up the tunnel.
#[cfg(not(feature = "ebpf"))]
pub enum Enforcer {}

#[cfg(not(feature = "ebpf"))]
impl Enforcer {
    pub fn new(_: &Policy) -> Result<Self> {
        anyhow::bail!(
            "This build cannot enforce an application filter: it was compiled without the `ebpf` feature"
        )
    }

    pub fn apply(&mut self, _: &ProtectedDestinations, _: &Interface) -> Result<()> {
        match *self {}
    }

    pub fn clear(&mut self) {
        match *self {}
    }
}
