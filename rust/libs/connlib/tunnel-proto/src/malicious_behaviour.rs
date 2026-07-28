use std::cell::Cell;

/// Returns `true` if the current thread is configured to ignore resource filters.
pub fn ignore_resource_filter() -> bool {
    FEATURES.with(|f| f.get().ignore_resource_filters)
}

/// Returns `true` if the current thread is configured to ignore its own flow tracking.
pub fn ignore_flow_tracking() -> bool {
    FEATURES.with(|f| f.get().ignore_flow_tracking)
}

#[derive(Debug, Clone, Copy, Default)]
pub struct MaliciousBehaviour {
    pub ignore_resource_filters: bool,
    pub ignore_flow_tracking: bool,
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
