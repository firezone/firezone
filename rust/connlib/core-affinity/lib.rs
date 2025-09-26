#![cfg_attr(test, allow(clippy::unwrap_used))]

#[derive(Debug, Clone, Copy)]
pub enum ThreadId {
    TunSend = 0,
    TunRecv = 1,
    UdpV4 = 2,
    UdpV6 = 3,
    Main = 4,
}

const NUM_THREADS: usize = 5; // Should be equal to number of variants in `ThreadId`.

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
pub fn set_core_affinity(thread: ThreadId) {
    let Some(core_ids) = core_affinity::get_core_ids() else {
        tracing::debug!("Unable to retrieve core IDs");
        return;
    };

    if core_ids.len() < NUM_THREADS {
        tracing::debug!(num_cores = %core_ids.len(), num_threads = %NUM_THREADS, "Not enough cores to uniquely assign threads");
        return;
    }

    let Some(core) = core_ids.get(thread as usize) else {
        tracing::debug!(?thread, "Failed to get core by index");
        return;
    };

    let result = core_affinity::set_for_current(*core);

    if !result {
        tracing::info!(?thread, ?core, "Failed to set core affinity");
        return;
    }

    tracing::debug!(?thread, ?core, "Set core affinity");
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
pub fn set_core_affinity(_: ThreadId) {
    tracing::debug!("MacOS / iOS do not support setting core affinity");
    return;
}
