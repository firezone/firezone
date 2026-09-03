//! Atomic and durable counterparts to the write operations in [`std::fs`].
//!
//! Each function writes to a temporary file in the target's directory, fsyncs it
//! and renames it into place, so a reader never observes a partial file and a
//! crash or power loss mid-write leaves the previous contents intact.
//!
//! Files are created with mode `0600` on Unix.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::fs::File;
use std::io::{self, Write as _};
use std::path::Path;

/// Atomically writes `contents` to `path`, replacing any existing file.
///
/// The atomic counterpart to [`std::fs::write`].
pub fn write(path: impl AsRef<Path>, contents: impl AsRef<[u8]>) -> io::Result<()> {
    let path = path.as_ref();
    let dir = path.parent().filter(|dir| !dir.as_os_str().is_empty());
    let dir = dir.unwrap_or(Path::new("."));

    let mut file = tempfile::NamedTempFile::new_in(dir)?;
    file.write_all(contents.as_ref())?;
    file.as_file().sync_all()?;
    file.persist(path)?;

    // The rename is only durable once the directory entry is on disk too.
    #[cfg(unix)]
    File::open(dir)?.sync_all()?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_and_overwrites() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("file");

        write(&path, b"one").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"one");

        write(&path, b"two").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"two");

        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
    }

    #[test]
    fn missing_directory_is_an_io_error() {
        let dir = tempfile::tempdir().unwrap();

        let e = write(dir.path().join("missing").join("file"), b"x").unwrap_err();

        assert_eq!(e.kind(), io::ErrorKind::NotFound);
    }

    #[cfg(unix)]
    #[test]
    fn file_is_owner_only() {
        use std::os::unix::fs::PermissionsExt as _;

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("file");

        write(&path, b"secret").unwrap();

        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
