use anyhow::{Context, Result};
use std::{
    ffi::OsStr,
    io::ErrorKind::NotFound,
    path::{Path, PathBuf},
};

/// Deletes all `.log` and `.jsonl` files in `path` except the most recent
pub async fn clear_logs(path: &Path) -> Result<()> {
    let mut dir = match tokio::fs::read_dir(path).await {
        Ok(x) => x,
        Err(error) => {
            if matches!(error.kind(), NotFound) {
                // In smoke tests, the IPC service runs in debug mode, so it won't write any logs to disk. If the IPC service's log dir doesn't exist, we shouldn't crash, it's correct to simply not delete the non-existent files
                return Ok(());
            }
            // But any other error like permissions errors, should bubble.
            return Err(error.into());
        }
    };
    let mut paths = vec![];
    while let Some(entry) = dir.next_entry().await? {
        paths.push(entry.path());
    }

    // If we can't delete some files due to permission errors, just keep going
    // and delete as much as we can, then return the most recent error
    let mut result = Ok(());
    let to_delete = choose_logs_to_delete(&paths);
    for path in &to_delete {
        if let Err(e) = tokio::fs::remove_file(path).await {
            result = Err(e);
        }
    }
    result.context("Failed to delete at least one file")
}

fn choose_logs_to_delete(paths: &[PathBuf]) -> Vec<&Path> {
    let mut most_recent_stem = None;
    for path in paths {
        if path.extension() != Some(OsStr::new("log")) {
            continue;
        }
        let Some(stem) = path.file_stem() else {
            continue;
        };
        match most_recent_stem {
            None => most_recent_stem = Some(stem),
            Some(most_recent) if stem > most_recent => most_recent_stem = Some(stem),
            Some(_) => {}
        }
    }
    let Some(most_recent_stem) = most_recent_stem else {
        tracing::warn!(
            "Nothing to delete, should be impossible since both processes always write logs"
        );
        return vec![];
    };
    let Some(most_recent_stem) = most_recent_stem.to_str() else {
        tracing::warn!("Most recent log file does not have a UTF-8 path");
        return vec![];
    };

    paths
        .iter()
        .filter_map(|path| {
            // Don't delete files if we can't parse their stems as UTF-8.
            let stem = path.file_stem()?.to_str()?;

            (stem < most_recent_stem).then_some(path.as_path())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    #[test]
    fn clear_logs_logic() {
        // These are out of order just to make sure it works anyway
        let paths: Vec<_> = [
            "connlib.2024-08-05-19-41-46.jsonl",
            "connlib.2024-08-05-19-41-46.log",
            "connlib.2024-08-07-14-17-56.jsonl",
            "connlib.2024-08-07-14-17-56.log",
            "connlib.2024-08-06-14-21-13.jsonl",
            "connlib.2024-08-06-14-21-13.log",
            "connlib.2024-08-06-14-51-19.jsonl",
            "connlib.2024-08-06-14-51-19.log",
            "crash.2024-07-22-21-16-20.dmp",
            "last_crash.dmp",
        ]
        .into_iter()
        .map(|x| Path::new("/bogus").join(x))
        .collect();
        let to_delete = super::choose_logs_to_delete(&paths);
        assert_eq!(
            to_delete,
            [
                "/bogus/connlib.2024-08-05-19-41-46.jsonl",
                "/bogus/connlib.2024-08-05-19-41-46.log",
                "/bogus/connlib.2024-08-06-14-21-13.jsonl",
                "/bogus/connlib.2024-08-06-14-21-13.log",
                "/bogus/connlib.2024-08-06-14-51-19.jsonl",
                "/bogus/connlib.2024-08-06-14-51-19.log",
            ]
            .into_iter()
            .map(Path::new)
            .collect::<Vec<_>>()
        );
    }
}
