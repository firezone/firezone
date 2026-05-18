//! Load and parse the root-managed allowlist file at.
//!
//! The file's own ownership/mode are validated to prevent a confused-deputy
//! attack: without that check, an attacker with write access to the file
//! alone could allowlist a root-owned interpreter like `/usr/bin/bash`
//! (which passes `target_safe`) and connect via `bash -c "..."` so
//! `/proc/<bash-pid>/exe` matches. Requiring the allowlist itself to be
//! root-owned closes that path.

use std::io;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

/// Read and parse the allowlist file.
#[tracing::instrument(level = "debug", skip_all, fields(path = %path.display()))]
pub fn read(path: &Path) -> Vec<PathBuf> {
    let metadata = match std::fs::metadata(path) {
        Ok(meta) => meta,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            tracing::debug!("Allowlist file is missing; no peers will be accepted");
            return Vec::new();
        }
        Err(error) => {
            tracing::debug!("Couldn't stat allowlist: {error}");
            return Vec::new();
        }
    };

    if metadata.uid() != 0 || metadata.gid() != 0 {
        tracing::debug!(
            uid = metadata.uid(),
            gid = metadata.gid(),
            "Allowlist must be owned by root:root; ignoring"
        );
        return Vec::new();
    }

    let mode = metadata.mode() & 0o777;
    if mode != 0o644 && mode != 0o640 {
        tracing::debug!(
            mode = format_args!("{mode:#o}"),
            "Allowlist must have mode 0644 or 0640; ignoring"
        );
        return Vec::new();
    }

    let contents = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(error) => {
            tracing::debug!("Couldn't read allowlist: {error}");
            return Vec::new();
        }
    };

    contents
        .lines()
        .filter_map(parse_line)
        .filter_map(canonicalise_entry)
        .collect()
}

fn parse_line(line: &str) -> Option<PathBuf> {
    let trimmed = line.split('#').next()?.trim();

    if trimmed.is_empty() {
        return None;
    }

    if !Path::new(trimmed).is_absolute() {
        tracing::debug!(entry = %trimmed, "Ignoring non-absolute allowlist entry");
        return None;
    }

    Some(PathBuf::from(trimmed))
}

fn canonicalise_entry(raw: PathBuf) -> Option<PathBuf> {
    let canonical = match std::fs::canonicalize(&raw) {
        Ok(p) => p,
        Err(error) => {
            tracing::debug!(entry = %raw.display(), "Ignoring allowlist entry: {error}");
            return None;
        }
    };

    if !target_safe(&canonical) {
        tracing::debug!(entry = %canonical.display(), "Ignoring allowlist entry: target or ancestor not root-owned, or is group/world-writable");
        return None;
    }

    Some(canonical)
}

/// True iff `path` and every ancestor up to the root are owned by uid 0
/// and not group- or world-writable.
///
/// Owner check (`uid == 0`) is what prevents a non-root user from
/// substituting the allowlisted binary by recreating it after the daemon
/// loads the allowlist: even if a `0755` directory along the path happens
/// to be writable only by its owner, that owner could replace the
/// allowlisted file if they're not root.
fn target_safe(path: &Path) -> bool {
    let mut current = Some(path);

    while let Some(p) = current {
        let Ok(meta) = std::fs::metadata(p) else {
            return false;
        };

        if meta.uid() != 0 {
            return false;
        }

        if meta.mode() & 0o022 != 0 {
            return false;
        }

        current = p.parent();
    }

    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;
    use std::os::unix::fs::PermissionsExt as _;
    use tempfile::NamedTempFile;

    #[test]
    fn parse_line_strips_comments_and_blanks() {
        assert_eq!(parse_line(""), None);
        assert_eq!(parse_line("   "), None);
        assert_eq!(parse_line("# comment"), None);
        assert_eq!(
            parse_line("/usr/bin/foo  # inline"),
            Some(PathBuf::from("/usr/bin/foo"))
        );
        assert_eq!(
            parse_line("  /usr/bin/foo"),
            Some(PathBuf::from("/usr/bin/foo"))
        );
        assert_eq!(parse_line("relative/path"), None);
    }

    #[test]
    fn read_rejects_non_root_owned_file() {
        let mut file = NamedTempFile::new().unwrap();
        writeln!(file, "/usr/bin/true").unwrap();
        // Tempfile is owned by the test user, not root → `read` rejects.
        assert!(read(file.path()).is_empty());
    }

    #[test]
    fn read_missing_returns_empty() {
        assert!(read(Path::new("/nonexistent/firezone/allowed-clients.conf")).is_empty());
    }

    #[test]
    fn target_safe_rejects_user_owned_tempfile() {
        // A tempfile under /tmp is owned by the test user → not root, so
        // `target_safe` rejects.
        let file = NamedTempFile::new().unwrap();
        let perms = std::fs::Permissions::from_mode(0o644);
        std::fs::set_permissions(file.path(), perms).unwrap();
        assert!(!target_safe(file.path()));
    }
}
