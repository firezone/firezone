use std::cell::Cell;

/// Returns `true` if the current thread is configured to ignore resource filters.
pub fn ignore_resource_filter() -> bool {
    FEATURES.with(|f| f.get().ignore_resource_filters)
}

/// Returns `true` if the current thread is configured to answer peers with ICMP errors
/// that no flow of its own covers.
pub fn send_untracked_icmp_errors() -> bool {
    FEATURES.with(|f| f.get().send_untracked_icmp_errors)
}

#[derive(Debug, Clone, Copy, Default)]
pub struct MaliciousBehaviour {
    pub ignore_resource_filters: bool,
    pub send_untracked_icmp_errors: bool,
}

impl MaliciousBehaviour {
    pub fn guard(&self) -> Guard {
        FEATURES.with(|f| f.set(*self));
        Guard
    }
}

/// RAII guard that resets the thread-local malicious behaviour flags on drop.
pub struct Guard;

impl Drop for Guard {
    fn drop(&mut self) {
        FEATURES.with(|f| f.set(MaliciousBehaviour::default()));
    }
}

thread_local! {
    static FEATURES: Cell<MaliciousBehaviour> = Cell::default();
}
