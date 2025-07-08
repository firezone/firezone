use std::time::Duration;

use anyhow::Result;
use perf_monitor::cpu::ProcessStat;

pub fn start(limit: f64) -> Result<()> {
    let mut process_stat = ProcessStat::cur()?;

    std::thread::spawn(move || {
        loop {
            std::thread::sleep(Duration::from_secs(5));

            let Ok(cpu_time) = process_stat.cpu() else {
                continue;
            };

            let cpu_time = cpu_time * 100_f64;

            if cpu_time > limit {
                tracing::warn!(%limit, %cpu_time, "Process CPU time exceeded");
                continue;
            }

            tracing::debug!(%limit, %cpu_time, "Process CPU time all normal");
        }
    });

    Ok(())
}
