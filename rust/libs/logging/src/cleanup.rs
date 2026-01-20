//! Log cleanup utilities for enforcing size caps on log directories.

use std::collections::BTreeMap;
use std::fs;
use std::io::ErrorKind;
use std::path::Path;
use std::time::{Duration, SystemTime};

/// Minimum age in seconds for files to be eligible for deletion.
/// Files modified more recently than this are protected.
const MIN_AGE_SECS: Duration = Duration::from_secs(300);

/// Enforces a size cap on log directories by deleting oldest files first.
/// FFI-friendly interface.
///
/// # Returns
/// Number of bytes deleted (best-effort, never fails)
///
/// # Behaviour
/// - Deletes oldest `.log` files first (by modification time)
/// - Protects files modified within the last 5 minutes
/// - Always keeps at least 1 file per directory
/// - Logs debug/warning messages for errors encountered during cleanup
pub fn enforce_size_cap(log_dirs: &[&Path], max_size_mb: u32) -> u64 {
    let max_bytes = u64::from(max_size_mb) * 1024 * 1024;
    let now = SystemTime::now();

    // Collect all log files with metadata: (path, size, mtime, parent_index)
    let mut files: Vec<(std::path::PathBuf, u64, SystemTime, usize)> = Vec::new();

    for (dir_idx, dir) in log_dirs.iter().enumerate() {
        if !dir.exists() {
            tracing::debug!(dir = %dir.display(), "Log directory does not exist, skipping");
            continue;
        }

        let entries = match fs::read_dir(dir) {
            Ok(e) => e,
            Err(e) => {
                match e.kind() {
                    ErrorKind::PermissionDenied => {
                        tracing::warn!(dir = %dir.display(), "Permission denied reading log directory");
                    }
                    ErrorKind::NotFound => {
                        tracing::debug!(dir = %dir.display(), "Log directory not found (removed after exists check)");
                    }
                    _ => {
                        tracing::warn!(dir = %dir.display(), error = %e, "Failed to read log directory");
                    }
                }
                continue;
            }
        };
        for entry_result in entries {
            let entry = match entry_result {
                Ok(e) => e,
                Err(e) => {
                    tracing::debug!(dir = %dir.display(), error = %e, "Failed to read directory entry, skipping");
                    continue;
                }
            };
            let path = entry.path();
            // Only process .log files, skip symlinks like "latest"
            if path.extension().is_none_or(|e| e != "log") {
                continue;
            }
            let meta = match entry.metadata() {
                Ok(m) => m,
                Err(e) => {
                    tracing::debug!(path = %path.display(), error = %e, "Failed to read file metadata, skipping");
                    continue;
                }
            };
            if !meta.is_file() {
                continue;
            }
            let mtime = match meta.modified() {
                Ok(t) => t,
                Err(e) => {
                    tracing::debug!(path = %path.display(), error = %e, "Cannot read modification time, treating as recent");
                    now
                }
            };
            files.push((path, meta.len(), mtime, dir_idx));
        }
    }

    // Sort oldest first
    files.sort_by_key(|(_, _, mtime, _)| *mtime);

    // Calculate total size
    let total_size: u64 = files.iter().map(|(_, size, _, _)| size).sum();

    if total_size <= max_bytes {
        return 0;
    }

    // Count files per directory
    let mut files_per_dir: BTreeMap<usize, usize> = BTreeMap::new();
    for (_, _, _, dir_idx) in &files {
        *files_per_dir.entry(*dir_idx).or_insert(0) += 1;
    }

    // Delete oldest until under threshold
    let mut deleted_bytes = 0u64;
    let mut current_size = total_size;

    for (path, size, mtime, dir_idx) in &files {
        if current_size <= max_bytes {
            break;
        }

        // Skip if too recent
        if let Ok(age) = now.duration_since(*mtime) {
            if age < MIN_AGE_SECS {
                continue;
            }
        } else {
            // mtime is in the future, skip
            continue;
        }

        // Keep at least 1 file per directory
        if let Some(count) = files_per_dir.get_mut(dir_idx) {
            if *count <= 1 {
                continue;
            }
            *count -= 1;
        }

        // Delete the file
        match fs::remove_file(path) {
            Ok(()) => {
                deleted_bytes += size;
                current_size -= size;
            }
            Err(e) => {
                match e.kind() {
                    ErrorKind::NotFound => {
                        // File was deleted by another process - benign
                        tracing::debug!(path = %path.display(), "Log file already deleted");
                    }
                    ErrorKind::PermissionDenied => {
                        tracing::warn!(path = %path.display(), "Permission denied deleting old log file");
                    }
                    _ => {
                        tracing::warn!(path = %path.display(), error = %e, "Failed to delete old log file");
                    }
                }
            }
        }
    }

    if current_size > max_bytes {
        tracing::debug!(
            current_size_mb = current_size / 1024 / 1024,
            max_size_mb,
            "Log size still over threshold after cleanup (recent files protected)"
        );
    }

    deleted_bytes
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::io::Write;
    use std::thread;
    use std::time::Duration;
    use tempfile::TempDir;

    fn create_log_file(dir: &Path, name: &str, size_bytes: usize) -> std::path::PathBuf {
        let path = dir.join(name);
        let mut file = File::create(&path).unwrap();
        file.write_all(&vec![b'x'; size_bytes]).unwrap();
        path
    }

    #[test]
    fn test_no_deletion_when_under_threshold() {
        let dir = TempDir::new().unwrap();
        create_log_file(dir.path(), "test1.log", 1024); // 1 KB

        let deleted = enforce_size_cap(&[dir.path()], 1); // 1 MB limit
        assert_eq!(deleted, 0);

        // File should still exist
        assert!(dir.path().join("test1.log").exists());
    }

    #[test]
    fn test_deletes_oldest_when_over_threshold() {
        let dir = TempDir::new().unwrap();

        // Create old file first
        let old_file = create_log_file(dir.path(), "old.log", 600 * 1024); // 600 KB

        // Wait to ensure different mtime
        thread::sleep(Duration::from_millis(50));

        // Create newer file
        let new_file = create_log_file(dir.path(), "new.log", 600 * 1024); // 600 KB

        // Backdate the old file to make it eligible for deletion
        let old_time = SystemTime::now() - Duration::from_secs(600);
        filetime::set_file_mtime(&old_file, filetime::FileTime::from_system_time(old_time))
            .unwrap();

        // Total: 1.2 MB, limit: 1 MB
        let deleted = enforce_size_cap(&[dir.path()], 1);

        assert_eq!(deleted, 600 * 1024);
        assert!(!old_file.exists(), "Old file should be deleted");
        assert!(new_file.exists(), "New file should remain");
    }

    #[test]
    fn test_respects_min_age_protection() {
        let dir = TempDir::new().unwrap();

        // Create two files, both recent
        create_log_file(dir.path(), "file1.log", 600 * 1024);
        create_log_file(dir.path(), "file2.log", 600 * 1024);

        // Total: 1.2 MB, limit: 1 MB, but both files are recent
        let deleted = enforce_size_cap(&[dir.path()], 1);

        // Should not delete anything because both are too recent
        assert_eq!(deleted, 0);
    }

    #[test]
    fn test_keeps_at_least_one_file_per_directory() {
        let dir = TempDir::new().unwrap();

        // Create single large file
        let file = create_log_file(dir.path(), "only.log", 2 * 1024 * 1024); // 2 MB

        // Backdate it
        let old_time = SystemTime::now() - Duration::from_secs(600);
        filetime::set_file_mtime(&file, filetime::FileTime::from_system_time(old_time)).unwrap();

        // Limit: 1 MB, but we should keep the only file
        let deleted = enforce_size_cap(&[dir.path()], 1);

        assert_eq!(deleted, 0);
        assert!(file.exists(), "Should keep at least one file");
    }

    #[test]
    fn test_handles_empty_directories() {
        let dir = TempDir::new().unwrap();

        let deleted = enforce_size_cap(&[dir.path()], 100);
        assert_eq!(deleted, 0);
    }

    #[test]
    fn test_handles_nonexistent_directories() {
        let nonexistent = Path::new("/nonexistent/path/that/does/not/exist");

        let deleted = enforce_size_cap(&[nonexistent], 100);
        assert_eq!(deleted, 0);
    }

    #[test]
    fn test_multiple_directories() {
        let dir1 = TempDir::new().unwrap();
        let dir2 = TempDir::new().unwrap();

        // Create files in both directories
        let old1 = create_log_file(dir1.path(), "old1.log", 400 * 1024);
        let old2 = create_log_file(dir2.path(), "old2.log", 400 * 1024);
        thread::sleep(Duration::from_millis(50));
        let new1 = create_log_file(dir1.path(), "new1.log", 400 * 1024);
        let new2 = create_log_file(dir2.path(), "new2.log", 400 * 1024);

        // Backdate old files
        let old_time = SystemTime::now() - Duration::from_secs(600);
        filetime::set_file_mtime(&old1, filetime::FileTime::from_system_time(old_time)).unwrap();
        filetime::set_file_mtime(&old2, filetime::FileTime::from_system_time(old_time)).unwrap();

        // Total: 1.6 MB, limit: 1 MB
        let deleted = enforce_size_cap(&[dir1.path(), dir2.path()], 1);

        // Should delete oldest files until under threshold
        assert!(deleted >= 400 * 1024);
        assert!(new1.exists());
        assert!(new2.exists());
    }

    #[test]
    fn test_skips_non_log_files() {
        let dir = TempDir::new().unwrap();

        // Create .log file and non-.log file
        let log_file = create_log_file(dir.path(), "test.log", 600 * 1024);
        let txt_file = dir.path().join("test.txt");
        File::create(&txt_file)
            .unwrap()
            .write_all(&vec![b'x'; 600 * 1024])
            .unwrap();

        // Backdate log file
        let old_time = SystemTime::now() - Duration::from_secs(600);
        filetime::set_file_mtime(&log_file, filetime::FileTime::from_system_time(old_time))
            .unwrap();
        filetime::set_file_mtime(&txt_file, filetime::FileTime::from_system_time(old_time))
            .unwrap();

        // Non-.log files should be ignored in size calculation
        let deleted = enforce_size_cap(&[dir.path()], 1);

        // .log file is under 1 MB, so nothing deleted
        assert_eq!(deleted, 0);
        assert!(txt_file.exists(), "Non-.log files should be untouched");
    }

    #[test]
    fn test_keeps_one_file_per_directory_when_multiple_dirs() {
        let dir1 = TempDir::new().unwrap();
        let dir2 = TempDir::new().unwrap();

        // Create two large old files in each directory
        let file1a = create_log_file(dir1.path(), "file1a.log", 500 * 1024);
        let file1b = create_log_file(dir1.path(), "file1b.log", 500 * 1024);
        let file2a = create_log_file(dir2.path(), "file2a.log", 500 * 1024);
        let file2b = create_log_file(dir2.path(), "file2b.log", 500 * 1024);

        // Backdate all files
        let old_time = SystemTime::now() - Duration::from_secs(600);
        for f in [&file1a, &file1b, &file2a, &file2b] {
            filetime::set_file_mtime(f, filetime::FileTime::from_system_time(old_time)).unwrap();
        }

        // Total: 2 MB, limit: 1 MB - aggressive cleanup
        let deleted = enforce_size_cap(&[dir1.path(), dir2.path()], 1);

        // Verify deletion occurred
        assert!(deleted > 0);

        // Count remaining .log files per directory
        let count_logs = |dir: &Path| -> usize {
            std::fs::read_dir(dir)
                .unwrap()
                .filter_map(|e| e.ok())
                .filter(|e| e.path().extension().is_some_and(|ext| ext == "log"))
                .count()
        };

        assert!(
            count_logs(dir1.path()) >= 1,
            "Dir1 should keep at least one file"
        );
        assert!(
            count_logs(dir2.path()) >= 1,
            "Dir2 should keep at least one file"
        );
    }
}
