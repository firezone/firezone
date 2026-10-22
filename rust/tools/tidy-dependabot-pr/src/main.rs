//! Tidies Dependabot pull requests so that squash-merged commit messages on
//! `main` stay short and compliant. Pure text in, text out: no network, no
//! GitHub API calls. CI writes the PR body to a file, runs this, and applies the
//! results with `gh`.
//!
//! Two modes, one per invocation:
//!
//! ```text
//! tidy-dependabot-pr title "<pr title>"                 # -> tidied title on stdout (empty if unchanged)
//! tidy-dependabot-pr body  <in> <out-body> [out-comment] # -> reads <in>, writes the tidied body and,
//!                                                        #    if worth keeping, the details comment
//! ```

// This is a CLI whose entire purpose is to print the transformed text; stdout and
// stderr are its interface, so the workspace's no-print lints don't apply here.
#![allow(clippy::print_stdout, clippy::print_stderr)]

use std::process::ExitCode;

const MARKER: &str = "<!-- tidy-dependabot-body:details -->";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("title") => {
            let title = args.get(1).map(String::as_str).unwrap_or_default();
            if let Some(tidied) = tidy_title(title) {
                println!("{tidied}");
            }
            ExitCode::SUCCESS
        }
        Some("body") => {
            let (Some(input), Some(out_body), out_comment) =
                (args.get(1), args.get(2), args.get(3))
            else {
                eprintln!("usage: tidy-dependabot-pr body <in> <out-body> [out-comment]");
                return ExitCode::from(2);
            };
            let body = match std::fs::read_to_string(input) {
                Ok(body) => body,
                Err(err) => {
                    eprintln!("cannot read {input}: {err}");
                    return ExitCode::FAILURE;
                }
            };
            if let Err(err) = std::fs::write(out_body, tidy_body(&body)) {
                eprintln!("cannot write {out_body}: {err}");
                return ExitCode::FAILURE;
            }
            // Write the comment file only when there is something to preserve, so
            // CI can just test whether the file exists.
            if let Some(path) = out_comment {
                match details_comment(&body) {
                    Some(comment) => {
                        if let Err(err) = std::fs::write(path, comment) {
                            eprintln!("cannot write {path}: {err}");
                            return ExitCode::FAILURE;
                        }
                    }
                    None => {
                        let _ = std::fs::remove_file(path);
                    }
                }
            }
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!(
                "usage:\n  tidy-dependabot-pr title \"<pr title>\"\n  \
                 tidy-dependabot-pr body <in> <out-body> [out-comment]"
            );
            ExitCode::from(2)
        }
    }
}

/// Reduces a grouped update's body to just its per-dependency `Updates` lines,
/// or returns an empty string for a single-dependency update.
///
/// A grouped update lists each member on its own ``Updates `dep` from X to Y``
/// line; a single-dependency update has none, so the filter naturally yields an
/// empty body (the PR title already says everything). Selecting lines this way
/// keeps it robust to anything Dependabot prepends, such as its "is rebasing"
/// banner on a grouped PR.
fn tidy_body(body: &str) -> String {
    body.lines()
        .filter(|line| line.starts_with("Updates "))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Shortens an over-long grouped-update title to `<prefix>: bump the <group> group`.
///
/// Handles both `build(deps): bump the foo group across 1 directory with 3
/// updates` and the multi-ecosystem form `Bump the "foo" group with 1 update
/// across multiple ecosystems`, which carries no conventional-commit prefix. The
/// existing prefix is kept when there is one; otherwise we default to
/// `build(deps)`. Returns `None` for a non-grouped title, or if the result still
/// wouldn't fit our 64-character limit.
fn tidy_title(title: &str) -> Option<String> {
    let group = group_name(title)?;
    let prefix = match title.split_once(':') {
        Some((prefix, _)) if !prefix.contains(' ') => prefix,
        _ => "build(deps)",
    };
    let candidate = format!("{prefix}: bump the {group} group");
    (candidate != title && candidate.len() <= 64).then_some(candidate)
}

/// Extracts the release notes, changelog and commit list into a comment body,
/// or returns `None` when there is nothing worth keeping.
///
/// Those sections are everything above Dependabot's footer, minus its transient
/// "is rebasing" banner. The footer starts at the compatibility badge, the
/// auto-merge markers, or the "Dependabot will resolve" line (a multi-ecosystem
/// PR has only the last of these). A comment is only produced when that content
/// actually contains a collapsible `<details>`.
fn details_comment(body: &str) -> Option<String> {
    let mut in_rebase_banner = false;
    let notes = body
        .lines()
        .take_while(|line| {
            !line.starts_with("[![Dependabot compatibility score]")
                && !line.starts_with("[//]: # (dependabot-automerge-start)")
                && !line.starts_with("Dependabot will resolve")
        })
        .filter(|line| {
            if line.starts_with("[//]: # (dependabot-start)") {
                in_rebase_banner = true;
            }
            let keep = !in_rebase_banner;
            if line.starts_with("[//]: # (dependabot-end)") {
                in_rebase_banner = false;
            }
            keep
        })
        .collect::<Vec<_>>()
        .join("\n");

    notes
        .contains("<details>")
        .then(|| format!("{MARKER}\n\n{}", notes.trim()))
}

/// Extracts the group name from a `... the <name> group ...` phrase.
///
/// Works on both a PR title and a body's first line, and unwraps the quotes
/// Dependabot puts around multi-ecosystem group names (`the "foo" group`).
/// Returns `None` if there is no such single-token group reference.
fn group_name(text: &str) -> Option<&str> {
    let before_group = text.split_once(" group")?.0;
    let name = before_group.rsplit_once(" the ")?.1.trim_matches('"');
    (!name.is_empty() && !name.contains(' ')).then_some(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SINGLE: &str = r#"Bumps [uuid](https://github.com/uuid-rs/uuid) from 1.23.2 to 1.23.5.
<details>
<summary>Release notes</summary>
<blockquote>v1.23.5 stuff</blockquote>
</details>
<details>
<summary>Commits</summary>
<ul><li>abc123 prepare release</li></ul>
</details>
<br />

[![Dependabot compatibility score](https://dependabot-badges.githubapp.com/x)](https://docs.github.com/y)

Dependabot will resolve any conflicts with this PR as long as you don't alter it yourself. You can also trigger a rebase manually by commenting `@dependabot rebase`.

[//]: # (dependabot-automerge-start)
[//]: # (dependabot-automerge-end)

---

<details>
<summary>Dependabot commands and options</summary>
commands here
</details>"#;

    const GROUPED: &str = r#"Bumps the rust-crypto group in /rust with 2 updates: [aes](https://x) and [sha2](https://y).

Updates `aes` from 0.8.3 to 0.8.4
<details>
<summary>Commits</summary>
<ul><li>aaa aes</li></ul>
</details>

Updates `sha2` from 0.10.7 to 0.10.8
<details>
<summary>Release notes</summary>
<blockquote>sha2 notes</blockquote>
</details>

[![Dependabot compatibility score](https://dependabot-badges.githubapp.com/x)](https://docs.github.com/y)

Dependabot will resolve any conflicts with this PR as long as you don't alter it yourself.

[//]: # (dependabot-automerge-start)
[//]: # (dependabot-automerge-end)"#;

    // A multi-ecosystem group PR body captured mid-rebase (see #14178): prefixed
    // with Dependabot's "is rebasing" banner, with no compatibility badge or
    // auto-merge marker. (The quoted group name appears in the title, exercised
    // by the tidy_title tests.)
    const MULTI_ECOSYSTEM: &str = r#"[//]: # (dependabot-start)
⚠️  **Dependabot is rebasing this PR** ⚠️

Rebasing might not happen immediately, so don't worry if this takes some time.

---

[//]: # (dependabot-end)

Bumps the tauri group in /rust with 2 updates: [tauri](https://github.com/tauri-apps/tauri) and [tauri-winrt-notification](https://github.com/tauri-apps/winrt-notification).

Updates `tauri` from 2.11.4 to 2.11.5
<details>
<summary>Commits</summary>
<ul><li>7cd7136 apply version updates</li></ul>
</details>
<br />

Updates `tauri-winrt-notification` from 0.7.2 to 0.8.0
<details>
<summary>Commits</summary>
<ul><li>4dc872e publish new versions</li></ul>
</details>
<br />


Dependabot will resolve any conflicts with this PR as long as you don't alter it yourself."#;

    #[test]
    fn single_update_clears_the_body() {
        assert_eq!(tidy_body(SINGLE), "");
    }

    #[test]
    fn grouped_update_keeps_only_the_dependency_lines() {
        assert_eq!(
            tidy_body(GROUPED),
            "Updates `aes` from 0.8.3 to 0.8.4\n\
             Updates `sha2` from 0.10.7 to 0.10.8"
        );
    }

    #[test]
    fn shortens_a_multi_update_group_title() {
        assert_eq!(
            tidy_title("build(deps): bump the rust-crypto group across 1 directory with 2 updates")
                .as_deref(),
            Some("build(deps): bump the rust-crypto group"),
        );
    }

    #[test]
    fn shortens_a_single_in_group_title_and_keeps_the_prefix() {
        assert_eq!(
            tidy_title("build(deps-dev): bump com.android.application from 9.2.1 to 9.3.0 in /kotlin/android in the com-android group")
                .as_deref(),
            Some("build(deps-dev): bump the com-android group"),
        );
    }

    #[test]
    fn leaves_a_single_dependency_title_alone() {
        assert_eq!(
            tidy_title("build(deps): bump uuid from 1.23.2 to 1.23.5 in /rust"),
            None,
        );
    }

    #[test]
    fn is_idempotent_on_an_already_short_title() {
        assert_eq!(tidy_title("build(deps): bump the rust-crypto group"), None);
    }

    #[test]
    fn shortens_a_multi_ecosystem_title_without_a_prefix() {
        assert_eq!(
            tidy_title("Bump the \"tauri\" group with 1 update across multiple ecosystems")
                .as_deref(),
            Some("build(deps): bump the tauri group"),
        );
    }

    #[test]
    fn shortens_a_prefixed_multi_ecosystem_title() {
        assert_eq!(
            tidy_title(
                "build(deps): Bump the \"tauri\" group with 1 update across multiple ecosystems"
            )
            .as_deref(),
            Some("build(deps): bump the tauri group"),
        );
    }

    #[test]
    fn grouped_body_survives_a_rebase_banner() {
        assert_eq!(
            tidy_body(MULTI_ECOSYSTEM),
            "Updates `tauri` from 2.11.4 to 2.11.5\n\
             Updates `tauri-winrt-notification` from 0.7.2 to 0.8.0"
        );
    }

    #[test]
    fn comment_drops_the_rebase_banner_and_multi_ecosystem_footer() {
        let comment = details_comment(MULTI_ECOSYSTEM).expect("has release notes");
        assert!(comment.starts_with(MARKER));
        assert!(!comment.contains("is rebasing"));
        assert!(!comment.contains("dependabot-start"));
        assert!(!comment.contains("Dependabot will resolve"));
        assert!(comment.contains("Updates `tauri`"));
        assert!(comment.contains("<details>"));
    }

    #[test]
    fn comment_keeps_the_details_but_drops_the_footer() {
        let comment = details_comment(SINGLE).expect("single update has release notes");
        assert!(comment.starts_with(MARKER));
        assert!(comment.contains("Release notes"));
        assert!(comment.contains("Commits"));
        assert!(!comment.contains("compatibility score"));
        assert!(!comment.contains("Dependabot commands and options"));
    }

    #[test]
    fn no_comment_when_there_is_nothing_to_keep() {
        let body = "Bumps the foo group in /x with 1 update: bar.\n\n\
                    Updates `bar` from 1.0 to 2.0\n\n\
                    [![Dependabot compatibility score](https://x)](https://y)\n\n\
                    [//]: # (dependabot-automerge-start)";
        assert_eq!(details_comment(body), None);
    }
}
