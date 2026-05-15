// CLI tool that intentionally writes a markdown report to stdout when no
// `--output` is given.
#![allow(clippy::print_stdout)]

use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

use anyhow::{Context, Result, bail};
use cargo_lock::{Lockfile, Name, Package, SourceId, Version};
use clap::Parser;
use serde::Deserialize;

const CRATES_IO_API: &str = "https://crates.io/api/v1/crates";
const DIFF_RS: &str = "https://diff.rs";

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    /// Git ref to compare from (the version we are upgrading away from).
    #[arg(long, default_value = "origin/main")]
    base_ref: String,

    /// Git ref to compare to (the version we are upgrading to).
    #[arg(long, default_value = "HEAD")]
    head_ref: String,

    /// Path to `Cargo.lock`, relative to the repository root.
    #[arg(long, default_value = "rust/Cargo.lock")]
    lockfile_path: PathBuf,

    /// User-Agent sent to crates.io. Crates.io's crawler policy requires a
    /// header that uniquely identifies the caller and provides contact info.
    #[arg(
        long,
        env = "DEP_DIFF_USER_AGENT",
        default_value = "firezone-dep-diff (https://github.com/firezone/firezone)"
    )]
    user_agent: String,

    /// Delay between crates.io API calls, in milliseconds.
    #[arg(long, default_value_t = 250)]
    request_delay_ms: u64,

    /// Write the report to this file. Defaults to stdout.
    #[arg(long)]
    output: Option<PathBuf>,
}

#[derive(Deserialize)]
struct CratesIoResponse {
    #[serde(rename = "crate")]
    crate_: CrateInfo,
}

#[derive(Deserialize)]
struct CrateInfo {
    repository: Option<String>,
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|_| anyhow::anyhow!("failed to install rustls crypto provider"))?;

    let cli = Cli::parse();

    let base = load_lockfile_from_git(&cli.base_ref, &cli.lockfile_path)?;
    let head = load_lockfile_from_git(&cli.head_ref, &cli.lockfile_path)?;
    let changes = diff_lockfiles(&base, &head);

    if changes.is_empty() {
        return write_report(
            &cli.output,
            &format!(
                "_No dependency changes detected between `{}` and `{}` for `{}`._\n",
                cli.base_ref,
                cli.head_ref,
                cli.lockfile_path.display(),
            ),
        );
    }

    let client = reqwest::Client::builder()
        .user_agent(&cli.user_agent)
        .timeout(Duration::from_secs(15))
        .build()
        .context("build HTTP client")?;
    let report = render_report(
        &client,
        &cli.base_ref,
        &cli.head_ref,
        &cli.lockfile_path,
        &changes,
        Duration::from_millis(cli.request_delay_ms),
    )
    .await?;

    write_report(&cli.output, &report)
}

fn write_report(output: &Option<PathBuf>, report: &str) -> Result<()> {
    let Some(path) = output else {
        print!("{report}");
        return Ok(());
    };
    std::fs::write(path, report).with_context(|| format!("write report to {}", path.display()))
}

fn load_lockfile_from_git(git_ref: &str, path: &Path) -> Result<Vec<Package>> {
    let spec = format!("{}:{}", git_ref, path.display());
    let output = Command::new("git")
        .args(["show", &spec])
        .output()
        .with_context(|| format!("invoke `git show {spec}`"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("`git show {spec}` failed: {}", stderr.trim());
    }
    let content = std::str::from_utf8(&output.stdout)
        .with_context(|| format!("{spec} is not valid UTF-8"))?;
    let lockfile: Lockfile = content
        .parse()
        .with_context(|| format!("parse {spec} as Cargo.lock"))?;
    Ok(lockfile.packages)
}

#[derive(Debug, PartialEq, Eq)]
struct Change {
    name: Name,
    kind: ChangeKind,
}

#[derive(Debug, PartialEq, Eq)]
enum ChangeKind {
    /// One version replaced another. The most common case.
    Bump {
        from: Version,
        to: Version,
        from_crates_io: bool,
    },
    /// A version of this crate was newly added (no version of it existed before).
    Added {
        version: Version,
        on_crates_io: bool,
    },
    /// A version of this crate disappeared (no version of it remains).
    Removed { version: Version },
    /// Multiple versions changed at once and we cannot pair them up unambiguously.
    Multi {
        removed: Vec<Version>,
        added: Vec<Version>,
    },
}

fn diff_lockfiles(base_pkgs: &[Package], head_pkgs: &[Package]) -> Vec<Change> {
    let base = group_by_name(base_pkgs);
    let head = group_by_name(head_pkgs);

    let names: BTreeSet<&Name> = base.keys().chain(head.keys()).copied().collect();
    let empty = BTreeMap::new();

    names
        .into_iter()
        .filter_map(|name| {
            let b = base.get(name).unwrap_or(&empty);
            let h = head.get(name).unwrap_or(&empty);
            let removed: Vec<(Version, bool)> = b
                .iter()
                .filter(|(v, _)| !h.contains_key(*v))
                .map(|(v, pkg)| ((*v).clone(), is_crates_io(pkg)))
                .collect();
            let added: Vec<(Version, bool)> = h
                .iter()
                .filter(|(v, _)| !b.contains_key(*v))
                .map(|(v, pkg)| ((*v).clone(), is_crates_io(pkg)))
                .collect();
            if removed.is_empty() && added.is_empty() {
                return None;
            }
            Some(Change {
                name: name.clone(),
                kind: classify(removed, added),
            })
        })
        .collect()
}

fn group_by_name(packages: &[Package]) -> BTreeMap<&Name, BTreeMap<&Version, &Package>> {
    let mut map = BTreeMap::new();
    for pkg in packages {
        map.entry(&pkg.name)
            .or_insert_with(BTreeMap::new)
            .insert(&pkg.version, pkg);
    }
    map
}

fn is_crates_io(pkg: &Package) -> bool {
    pkg.source
        .as_ref()
        .is_some_and(SourceId::is_default_registry)
}

fn classify(mut removed: Vec<(Version, bool)>, mut added: Vec<(Version, bool)>) -> ChangeKind {
    match (removed.len(), added.len()) {
        (1, 1) => {
            let (from, from_crates_io) = removed.pop().expect("len == 1");
            let (to, to_crates_io) = added.pop().expect("len == 1");
            ChangeKind::Bump {
                from,
                to,
                from_crates_io: from_crates_io && to_crates_io,
            }
        }
        (0, 1) => {
            let (version, on_crates_io) = added.pop().expect("len == 1");
            ChangeKind::Added {
                version,
                on_crates_io,
            }
        }
        (1, 0) => {
            let (version, _) = removed.pop().expect("len == 1");
            ChangeKind::Removed { version }
        }
        _ => ChangeKind::Multi {
            removed: removed.into_iter().map(|(v, _)| v).collect(),
            added: added.into_iter().map(|(v, _)| v).collect(),
        },
    }
}

async fn render_report(
    client: &reqwest::Client,
    base_ref: &str,
    head_ref: &str,
    lockfile_path: &Path,
    changes: &[Change],
    request_delay: Duration,
) -> Result<String> {
    let mut out = String::new();
    out.push_str(&format!(
        "## Dependency diff\n\nComparing `{}` → `{}` for `{}`.\n\n",
        base_ref,
        head_ref,
        lockfile_path.display(),
    ));
    out.push_str("| Crate | Change | Diff | Repository |\n");
    out.push_str("| --- | --- | --- | --- |\n");

    let mut bumped = 0usize;
    let mut added = 0usize;
    let mut removed = 0usize;
    let mut multi = 0usize;

    for (i, change) in changes.iter().enumerate() {
        let repo = if needs_crates_io_lookup(&change.kind) {
            if i > 0 {
                tokio::time::sleep(request_delay).await;
            }
            fetch_repository(client, change.name.as_str())
                .await
                .unwrap_or(None)
        } else {
            None
        };
        out.push_str(&format_row(change, repo.as_deref()));
        match change.kind {
            ChangeKind::Bump { .. } => bumped += 1,
            ChangeKind::Added { .. } => added += 1,
            ChangeKind::Removed { .. } => removed += 1,
            ChangeKind::Multi { .. } => multi += 1,
        }
    }

    out.push_str(&format!(
        "\n**{} crate(s) changed**: {bumped} bumped, {added} added, {removed} removed",
        changes.len(),
    ));
    if multi > 0 {
        out.push_str(&format!(", {multi} ambiguous"));
    }
    out.push_str(".\n");
    Ok(out)
}

fn needs_crates_io_lookup(kind: &ChangeKind) -> bool {
    matches!(
        kind,
        ChangeKind::Bump {
            from_crates_io: true,
            ..
        } | ChangeKind::Added {
            on_crates_io: true,
            ..
        }
    )
}

async fn fetch_repository(client: &reqwest::Client, crate_name: &str) -> Result<Option<String>> {
    let url = format!("{CRATES_IO_API}/{crate_name}");
    let resp = client.get(&url).send().await?;
    if !resp.status().is_success() {
        return Ok(None);
    }
    let parsed: CratesIoResponse = resp.json().await?;
    Ok(parsed.crate_.repository)
}

fn format_row(change: &Change, repo_url: Option<&str>) -> String {
    let name_cell = format!("[`{0}`](https://crates.io/crates/{0})", change.name);
    let (change_cell, diff_cell) = match &change.kind {
        ChangeKind::Bump {
            from,
            to,
            from_crates_io,
        } => {
            let diff = if *from_crates_io {
                format!("[view diff]({DIFF_RS}/{}/{}/{}/)", change.name, from, to)
            } else {
                "—".to_string()
            };
            (format!("`{from}` → `{to}`"), diff)
        }
        ChangeKind::Added {
            version,
            on_crates_io,
        } => {
            let diff = if *on_crates_io {
                format!(
                    "[crates.io](https://crates.io/crates/{}/{})",
                    change.name, version
                )
            } else {
                "—".to_string()
            };
            (format!("added `{version}`"), diff)
        }
        ChangeKind::Removed { version } => (format!("removed `{version}`"), "—".to_string()),
        ChangeKind::Multi { removed, added } => {
            let r = removed
                .iter()
                .map(|v| format!("`{v}`"))
                .collect::<Vec<_>>()
                .join(", ");
            let a = added
                .iter()
                .map(|v| format!("`{v}`"))
                .collect::<Vec<_>>()
                .join(", ");
            (format!("removed {r} · added {a}"), "—".to_string())
        }
    };
    let repo_cell = repo_url
        .map(|u| format!("[{}]({})", short_repo(u), u))
        .unwrap_or_else(|| "—".to_string());
    format!("| {name_cell} | {change_cell} | {diff_cell} | {repo_cell} |\n")
}

/// Best-effort short label for a repository URL (e.g. `owner/repo` for GitHub).
fn short_repo(url: &str) -> String {
    let stripped = url.trim_end_matches('/');
    let parts: Vec<&str> = stripped.rsplit('/').take(2).collect();
    parts.into_iter().rev().collect::<Vec<_>>().join("/")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Construct test packages by parsing a tiny lockfile, so each test is
    /// faithful to what `cargo_lock` actually produces from a real `Cargo.lock`.
    fn lockfile(toml: &str) -> Vec<Package> {
        let lockfile: Lockfile = toml.parse().expect("test lockfile parses");
        lockfile.packages
    }

    fn registry_pkg(name: &str, version: &str) -> String {
        format!(
            r#"
[[package]]
name = "{name}"
version = "{version}"
source = "registry+https://github.com/rust-lang/crates.io-index"
"#
        )
    }

    fn header() -> &'static str {
        "version = 4\n"
    }

    fn ver(s: &str) -> Version {
        s.parse().expect("test version parses")
    }

    fn name(s: &str) -> Name {
        s.parse().expect("test crate name parses")
    }

    #[test]
    fn detects_clean_bump() {
        let base = lockfile(&format!("{}{}", header(), registry_pkg("serde", "1.0.0")));
        let head = lockfile(&format!("{}{}", header(), registry_pkg("serde", "1.0.1")));
        let changes = diff_lockfiles(&base, &head);
        assert_eq!(
            changes,
            vec![Change {
                name: name("serde"),
                kind: ChangeKind::Bump {
                    from: ver("1.0.0"),
                    to: ver("1.0.1"),
                    from_crates_io: true,
                },
            }]
        );
    }

    #[test]
    fn detects_added_crate() {
        let base = lockfile(header());
        let head = lockfile(&format!(
            "{}{}",
            header(),
            registry_pkg("new-crate", "0.1.0")
        ));
        let changes = diff_lockfiles(&base, &head);
        assert_eq!(
            changes,
            vec![Change {
                name: name("new-crate"),
                kind: ChangeKind::Added {
                    version: ver("0.1.0"),
                    on_crates_io: true,
                },
            }]
        );
    }

    #[test]
    fn detects_removed_crate() {
        let base = lockfile(&format!("{}{}", header(), registry_pkg("gone", "1.0.0")));
        let head = lockfile(header());
        let changes = diff_lockfiles(&base, &head);
        assert_eq!(
            changes,
            vec![Change {
                name: name("gone"),
                kind: ChangeKind::Removed {
                    version: ver("1.0.0"),
                },
            }]
        );
    }

    #[test]
    fn unchanged_crates_are_skipped() {
        let pkgs = format!(
            "{}{}{}",
            header(),
            registry_pkg("a", "1.0.0"),
            registry_pkg("b", "2.0.0")
        );
        let base = lockfile(&pkgs);
        let head = lockfile(&pkgs);
        assert_eq!(diff_lockfiles(&base, &head), vec![]);
    }

    #[test]
    fn multi_version_change_is_flagged_as_ambiguous() {
        // `serde` had only 1.0.0, now has 1.0.1 AND 2.0.0 — we can't say which
        // one "replaced" the original.
        let base = lockfile(&format!("{}{}", header(), registry_pkg("serde", "1.0.0")));
        let head = lockfile(&format!(
            "{}{}{}",
            header(),
            registry_pkg("serde", "1.0.1"),
            registry_pkg("serde", "2.0.0")
        ));
        let changes = diff_lockfiles(&base, &head);
        assert_eq!(
            changes,
            vec![Change {
                name: name("serde"),
                kind: ChangeKind::Multi {
                    removed: vec![ver("1.0.0")],
                    added: vec![ver("1.0.1"), ver("2.0.0")],
                },
            }]
        );
    }

    #[test]
    fn coexisting_versions_dont_trigger_change_for_unchanged_one() {
        // Both refs have serde 1.0.0; only 2.0.0 was bumped to 2.0.1.
        let base = lockfile(&format!(
            "{}{}{}",
            header(),
            registry_pkg("serde", "1.0.0"),
            registry_pkg("serde", "2.0.0")
        ));
        let head = lockfile(&format!(
            "{}{}{}",
            header(),
            registry_pkg("serde", "1.0.0"),
            registry_pkg("serde", "2.0.1")
        ));
        let changes = diff_lockfiles(&base, &head);
        assert_eq!(
            changes,
            vec![Change {
                name: name("serde"),
                kind: ChangeKind::Bump {
                    from: ver("2.0.0"),
                    to: ver("2.0.1"),
                    from_crates_io: true,
                },
            }]
        );
    }

    #[test]
    fn non_registry_sources_are_not_marked_as_crates_io() {
        // Workspace member crates have no source; git deps have a `git+` source.
        // Both should be classified as not-on-crates-io for diff-link purposes.
        let base = lockfile(&format!(
            r#"
{header}
[[package]]
name = "local"
version = "0.1.0"

[[package]]
name = "forked"
version = "1.0.0"
source = "git+https://github.com/foo/bar?branch=main#deadbeef"
"#,
            header = header(),
        ));
        let head = lockfile(&format!(
            r#"
{header}
[[package]]
name = "local"
version = "0.2.0"

[[package]]
name = "forked"
version = "1.1.0"
source = "git+https://github.com/foo/bar?branch=main#cafef00d"
"#,
            header = header(),
        ));
        let changes = diff_lockfiles(&base, &head);
        for change in &changes {
            let ChangeKind::Bump { from_crates_io, .. } = change.kind else {
                panic!("expected Bump, got {:?}", change.kind);
            };
            assert!(
                !from_crates_io,
                "{} should not be marked crates.io",
                change.name
            );
        }
    }

    #[test]
    fn bump_row_links_to_diff_rs() {
        let change = Change {
            name: name("serde"),
            kind: ChangeKind::Bump {
                from: ver("1.0.0"),
                to: ver("1.0.1"),
                from_crates_io: true,
            },
        };
        let row = format_row(&change, Some("https://github.com/serde-rs/serde"));
        assert!(row.contains("[view diff](https://diff.rs/serde/1.0.0/1.0.1/)"));
        assert!(row.contains("[serde-rs/serde](https://github.com/serde-rs/serde)"));
        assert!(row.contains("`1.0.0` → `1.0.1`"));
    }

    #[test]
    fn non_crates_io_bump_omits_diff_link() {
        let change = Change {
            name: name("forked"),
            kind: ChangeKind::Bump {
                from: ver("1.0.0"),
                to: ver("1.1.0"),
                from_crates_io: false,
            },
        };
        let row = format_row(&change, None);
        assert!(!row.contains("diff.rs"));
        assert!(row.contains("`1.0.0` → `1.1.0`"));
    }

    #[test]
    fn short_repo_extracts_owner_repo_from_github_url() {
        assert_eq!(
            short_repo("https://github.com/serde-rs/serde"),
            "serde-rs/serde"
        );
        assert_eq!(
            short_repo("https://github.com/serde-rs/serde/"),
            "serde-rs/serde"
        );
        assert_eq!(
            short_repo("https://gitlab.com/foo/bar/baz"),
            "bar/baz",
            "fallback shows last two path segments"
        );
    }
}
