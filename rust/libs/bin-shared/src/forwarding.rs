//! Kernel forwarding for the resources a device serves.
//!
//! The daemon forwards a served packet by writing it to the TUN device and letting the
//! kernel route it on. For that the host must forward packets and masquerade the tunnel
//! prefixes onto its LAN. This module sets both up when a device starts serving and
//! takes both down when it stops, touching only what it changed itself: a sysctl the
//! admin already set stays, a rule that already existed is left in place.
//!
//! Only Linux has this. Elsewhere, and where this fails, the daemon forwards in userspace.

use anyhow::Result;

/// Keeps the host forwarding and masquerading; dropping it undoes what was changed.
#[derive(Debug)]
pub struct KernelForwarding {
    #[cfg(target_os = "linux")]
    _guard: linux::Guard,
}

/// Sets the host up to forward and masquerade the traffic arriving on the tunnel interface.
pub fn enable() -> Result<KernelForwarding> {
    #[cfg(target_os = "linux")]
    {
        Ok(KernelForwarding {
            _guard: linux::enable(crate::TunDeviceManager::IFACE_NAME)?,
        })
    }

    #[cfg(not(target_os = "linux"))]
    {
        anyhow::bail!("Kernel forwarding is only available on Linux")
    }
}

/// Whether [`enable`] has a chance on this host: it must be Linux and either forward
/// already or let us turn forwarding on.
pub fn is_available() -> bool {
    #[cfg(target_os = "linux")]
    {
        linux::is_available()
    }

    #[cfg(not(target_os = "linux"))]
    {
        false
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use std::{fmt, process::Command};

    use anyhow::{Context as _, Result};

    const IPV4_FORWARD: &str = "/proc/sys/net/ipv4/ip_forward";
    const IPV6_FORWARD: &[&str] = &[
        "/proc/sys/net/ipv6/conf/all/forwarding",
        "/proc/sys/net/ipv6/conf/default/forwarding",
    ];

    /// The tunnel prefixes the portal hands out, masqueraded onto the LAN.
    const IPV4_TUNNEL_PREFIX: &str = "100.64.0.0/11";
    const IPV6_TUNNEL_PREFIX: &str = "fd00:2021:1111::/107";

    /// The LAN interface patterns the gateway's init script masqueraded on: wired and wireless.
    const LAN_INTERFACE_PATTERNS: &[&str] = &["e+", "w+"];

    #[derive(Debug)]
    pub(super) struct Guard {
        /// Sysctls we set, with the value to put back.
        sysctls: Vec<(&'static str, String)>,
        /// Rules we added, as the arguments after the table and chain action.
        rules: Vec<Rule>,
    }

    #[derive(Debug, Clone)]
    struct Rule {
        binary: &'static str,
        /// The table, when not the filter table; it goes before the action on the command line.
        table: Option<&'static str>,
        chain: &'static str,
        /// The match and target, after the chain.
        args: Vec<String>,
    }

    impl Rule {
        /// The command line for `action` on this rule, with the table in front as `iptables` wants it.
        fn command(&self, action: &[&str]) -> Vec<String> {
            ["-w", "5"]
                .into_iter()
                .chain(self.table.iter().flat_map(|table| ["-t", table]))
                .chain(action.iter().copied())
                .map(str::to_owned)
                .chain(self.args.iter().cloned())
                .collect()
        }
    }

    pub(super) fn is_available() -> bool {
        read_sysctl(IPV4_FORWARD).as_deref() == Some("1")
            || std::fs::OpenOptions::new()
                .write(true)
                .open(IPV4_FORWARD)
                .is_ok()
    }

    pub(super) fn enable(tun_interface: &str) -> Result<Guard> {
        let mut guard = Guard {
            sysctls: Vec::new(),
            rules: Vec::new(),
        };

        let forwarding_was_on = read_sysctl(IPV4_FORWARD).as_deref() == Some("1");

        set_sysctl(&mut guard, IPV4_FORWARD).context("Failed to enable IPv4 forwarding")?;
        for path in IPV6_FORWARD {
            if let Err(e) = set_sysctl(&mut guard, path) {
                tracing::warn!(
                    "Failed to enable IPv6 forwarding, IPv6 resources will not be reachable: {e:#}"
                );
            }
        }

        for rule in rules(tun_interface) {
            match add_rule(&mut guard, rule) {
                Ok(()) => {}
                // A packaged install runs the daemon without root, which cannot manage
                // the rules; an admin who turned forwarding on has added them, as the
                // docs say, so the host is taken at its word.
                Err(AddRuleError::CannotManage(e)) if forwarding_was_on => {
                    tracing::warn!(
                        "Cannot manage the forwarding rules, assuming the host's own since it forwards already: {e:#}"
                    );
                    break;
                }
                Err(e) => {
                    // The guard drops what we did so far.
                    return Err(anyhow::Error::from(e)).context("Failed to add forwarding rule");
                }
            }
        }

        tracing::info!(
            sysctls = guard.sysctls.len(),
            rules = guard.rules.len(),
            "Kernel forwarding enabled"
        );

        Ok(guard)
    }

    impl Drop for Guard {
        fn drop(&mut self) {
            for rule in self.rules.drain(..).rev() {
                match run(rule.binary, rule.command(&["-D", rule.chain])) {
                    Ok(()) => {}
                    Err(e) => tracing::warn!(?rule, "Failed to remove forwarding rule: {e}"),
                }
            }

            for (path, value) in self.sysctls.drain(..) {
                if let Err(e) = std::fs::write(path, &value) {
                    tracing::warn!(%path, %value, "Failed to restore sysctl: {e:#}");
                }
            }

            tracing::info!("Kernel forwarding disabled");
        }
    }

    fn read_sysctl(path: &str) -> Option<String> {
        std::fs::read_to_string(path)
            .ok()
            .map(|v| v.trim().to_owned())
    }

    /// Sets `path` to 1, remembering the old value if we changed it.
    fn set_sysctl(guard: &mut Guard, path: &'static str) -> Result<()> {
        let current = read_sysctl(path).with_context(|| format!("Failed to read {path}"))?;

        if current == "1" {
            return Ok(());
        }

        std::fs::write(path, "1\n").with_context(|| format!("Failed to write {path}"))?;
        guard.sysctls.push((path, current));

        Ok(())
    }

    /// The rules the gateway's init script added, as `iptables` arguments after the action.
    fn rules(tun: &str) -> Vec<Rule> {
        let mut rules = Vec::new();

        for (binary, prefix) in [
            ("iptables", IPV4_TUNNEL_PREFIX),
            ("ip6tables", IPV6_TUNNEL_PREFIX),
        ] {
            for direction in ["-i", "-o"] {
                rules.push(Rule {
                    binary,
                    table: None,
                    chain: "FORWARD",
                    args: [direction, tun, "-j", "ACCEPT"].map(str::to_owned).to_vec(),
                });
            }

            for pattern in LAN_INTERFACE_PATTERNS {
                rules.push(Rule {
                    binary,
                    table: Some("nat"),
                    chain: "POSTROUTING",
                    args: ["-s", prefix, "-o", pattern, "-j", "MASQUERADE"]
                        .map(str::to_owned)
                        .to_vec(),
                });
            }
        }

        rules
    }

    enum AddRuleError {
        /// The rules cannot be checked or changed at all, as without root.
        CannotManage(anyhow::Error),
        Other(anyhow::Error),
    }

    impl From<AddRuleError> for anyhow::Error {
        fn from(e: AddRuleError) -> Self {
            match e {
                AddRuleError::CannotManage(e) => e.context("Cannot manage the rules"),
                AddRuleError::Other(e) => e,
            }
        }
    }

    /// Adds `rule` unless it exists; forward rules go first in their chain, as the init
    /// script inserted them, so a firewall's drop policy does not catch tunnel traffic.
    fn add_rule(guard: &mut Guard, rule: Rule) -> Result<(), AddRuleError> {
        match run(rule.binary, rule.command(&["-C", rule.chain])) {
            Ok(()) => {
                tracing::debug!(?rule, "Forwarding rule exists, leaving it to its owner");
                return Ok(());
            }
            // `-C` exits 1 for a rule that is not there and otherwise for trouble.
            Err(RunError::Status { code: Some(1), .. }) => {}
            Err(e) => return Err(AddRuleError::CannotManage(e.into())),
        }

        // Forward rules go first in their chain, as the init script inserted them.
        let action: &[&str] = if rule.table.is_none() {
            &["-I", rule.chain, "1"]
        } else {
            &["-A", rule.chain]
        };

        run(rule.binary, rule.command(action)).map_err(|e| AddRuleError::Other(e.into()))?;
        guard.rules.push(rule);

        Ok(())
    }

    #[derive(Debug)]
    enum RunError {
        Spawn {
            binary: String,
            source: std::io::Error,
        },
        Status {
            command: String,
            status: std::process::ExitStatus,
            code: Option<i32>,
            stderr: String,
        },
    }

    impl fmt::Display for RunError {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            match self {
                RunError::Spawn { binary, .. } => write!(f, "Failed to run `{binary}`"),
                RunError::Status {
                    command,
                    status,
                    stderr,
                    ..
                } => write!(f, "`{command}` failed with {status}: {stderr}"),
            }
        }
    }

    impl std::error::Error for RunError {
        fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
            match self {
                RunError::Spawn { source, .. } => Some(source),
                RunError::Status { .. } => None,
            }
        }
    }

    fn run(binary: &str, args: Vec<String>) -> Result<(), RunError> {
        let output = Command::new(binary)
            .args(&args)
            .output()
            .map_err(|source| RunError::Spawn {
                binary: binary.to_owned(),
                source,
            })?;

        if !output.status.success() {
            return Err(RunError::Status {
                command: format!("{binary} {}", args.join(" ")),
                status: output.status,
                code: output.status.code(),
                stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            });
        }

        Ok(())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn forward_rule_goes_first_in_the_filter_table() {
            let rule = &rules("tun-firezone")[0];

            assert_eq!(
                rule.command(&["-I", rule.chain, "1"]),
                [
                    "-w",
                    "5",
                    "-I",
                    "FORWARD",
                    "1",
                    "-i",
                    "tun-firezone",
                    "-j",
                    "ACCEPT"
                ]
            );
        }

        #[test]
        fn nat_rule_names_the_table_before_the_action() {
            let rule = &rules("tun-firezone")[2];

            assert_eq!(
                rule.command(&["-C", rule.chain]),
                [
                    "-w",
                    "5",
                    "-t",
                    "nat",
                    "-C",
                    "POSTROUTING",
                    "-s",
                    "100.64.0.0/11",
                    "-o",
                    "e+",
                    "-j",
                    "MASQUERADE"
                ]
            );
        }
    }
}
