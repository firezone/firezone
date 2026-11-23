use std::time::Duration;

use anyhow::{Context as _, Result};

use crate::Thread;

pub fn threads() -> Result<Vec<Thread>> {
    // SAFETY: `sysconf` has no preconditions.
    let ticks_per_second = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    let ticks_per_second = u64::try_from(ticks_per_second)
        .ok()
        .filter(|ticks| *ticks > 0)
        .context("Failed to get clock ticks per second")?;

    let mut threads = Vec::new();

    for entry in std::fs::read_dir("/proc/self/task").context("Failed to list `/proc/self/task`")? {
        let path = entry.context("Failed to list `/proc/self/task`")?.path();
        let id = path
            .file_name()
            .and_then(|name| name.to_str()?.parse::<u64>().ok())
            .with_context(|| format!("Invalid thread ID in `{}`", path.display()))?;
        let stat = std::fs::read_to_string(path.join("stat"))
            .with_context(|| format!("Failed to read `{}/stat`", path.display()))?;
        let (name, ticks) = parse_stat(&stat)
            .with_context(|| format!("Failed to parse `{}/stat`", path.display()))?;

        threads.push(Thread {
            id,
            name: name.to_owned(),
            cpu_time: Duration::from_nanos(ticks * 1_000_000_000 / ticks_per_second),
        });
    }

    Ok(threads)
}

/// Parses the name and the user plus system time in clock ticks from a `/proc/<pid>/task/<tid>/stat` file.
///
/// The name is in parentheses and may itself contain spaces and parentheses.
fn parse_stat(stat: &str) -> Result<(&str, u64)> {
    let (head, tail) = stat.rsplit_once(')').context("Missing `)` after name")?;
    let (_, name) = head.split_once('(').context("Missing `(` before name")?;

    // `tail` starts at the third field, `utime` and `stime` are the 14th and 15th.
    let mut times = tail.split_whitespace().skip(11);
    let utime = times
        .next()
        .context("Missing `utime`")?
        .parse::<u64>()
        .context("Failed to parse `utime`")?;
    let stime = times
        .next()
        .context("Missing `stime`")?
        .parse::<u64>()
        .context("Failed to parse `stime`")?;

    Ok((name, utime + stime))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_name_and_cpu_ticks() {
        let stat = "4242 (fz-crypto-0) S 4200 4200 4200 0 -1 4194624 31 0 0 0 1234 567 0 0 20 0 9 0 3518 1094955008 4710 18446744073709551615 0 0 0 0 0 0 0 4096 1088 0 0 0 -1 3 0 0 0 0 0";

        assert_eq!(parse_stat(stat).unwrap(), ("fz-crypto-0", 1801));
    }

    #[test]
    fn name_may_contain_spaces_and_parentheses() {
        let stat = "7 (a) b (c)) R 1 1 1 0 -1 0 0 0 0 0 10 20 0 0 20 0 1 0 1 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0";

        assert_eq!(parse_stat(stat).unwrap(), ("a) b (c)", 30));
    }

    #[test]
    fn lists_the_current_thread() {
        let name = std::thread::current().name().unwrap().to_owned();

        let threads = threads().unwrap();

        assert!(threads.iter().any(|thread| name.starts_with(&thread.name)));
    }
}
