use anyhow::{Context, Result};
use std::{io::ErrorKind::NotFound, path::Path};

/// Deletes all `.log` files in `path`.
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

    let mut result = Ok(());

    // If we can't delete some files due to permission errors, just keep going
    // and delete as much as we can, then return the most recent error
    while let Some(entry) = dir
        .next_entry()
        .await
        .context("Failed to read next dir entry")?
    {
        if entry
            .file_name()
            .to_str()
            .is_none_or(|name| !name.ends_with("log"))
        {
            continue;
        }

        if let Err(e) = tokio::fs::remove_file(entry.path()).await {
            result = Err(e);
        }
    }

    result.context("Failed to delete at least one file")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn only_deletes_log_files() {
        let dir = tempfile::tempdir().unwrap();

        std::fs::write(dir.path().join("first.log"), "log file 1").unwrap();
        std::fs::write(dir.path().join("second.log"), "log file 1").unwrap();
        std::fs::write(dir.path().join("not_a_logfile.tmp"), "something important").unwrap();

        clear_logs(dir.path()).await.unwrap();

        assert_eq!(
            std::fs::read_to_string(dir.path().join("not_a_logfile.tmp")).unwrap(),
            "something important"
        );
    }
}
