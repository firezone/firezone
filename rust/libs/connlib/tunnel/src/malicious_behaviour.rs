use std::cell::Cell;

/// Returns `true` if the current thread is configured to ignore resource filters.
pub(crate) fn ignore_resource_filter() -> bool {
    FEATURES.with(|f| f.get().ignore_resource_filters)
}

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct MaliciousBehaviour {
    pub(crate) ignore_resource_filters: bool,
}

impl MaliciousBehaviour {
    pub(crate) fn guard(&self) -> Guard {
        FEATURES.with(|f| f.set(*self));
        Guard
    }
}

/// RAII guard that resets the thread-local malicious behaviour flags on drop.
pub(crate) struct Guard;

impl Drop for Guard {
    fn drop(&mut self) {
        FEATURES.with(|f| f.set(MaliciousBehaviour::default()));
    }
}

thread_local! {
    static FEATURES: Cell<MaliciousBehaviour> = Cell::default();
}
