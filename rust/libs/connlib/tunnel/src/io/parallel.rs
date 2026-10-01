use std::sync::LazyLock;

use rayon::{ThreadPool, ThreadPoolBuilder, prelude::*};

/// Below this many jobs, waking the pool costs more than running them on the current thread.
const MIN_PARALLEL_JOBS: usize = 8;

static POOL: LazyLock<Option<ThreadPool>> = LazyLock::new(|| {
    ThreadPoolBuilder::new()
        .thread_name(|i| format!("connlib-crypto-{i}"))
        .build()
        .inspect_err(|e| tracing::warn!("Failed to start crypto thread pool: {e}"))
        .ok()
});

/// Runs `job` on every item, spreading them across a thread pool if there are enough.
pub(crate) fn for_each<T: Send>(items: Vec<T>, job: impl Fn(T) + Send + Sync) {
    let Some(pool) = POOL.as_ref().filter(|_| items.len() >= MIN_PARALLEL_JOBS) else {
        for item in items {
            job(item);
        }

        return;
    };

    pool.install(|| items.into_par_iter().for_each(job));
}
