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
    let Some(pool) = pool_for(items.len()) else {
        for item in items {
            job(item);
        }

        return;
    };

    pool.install(|| items.into_par_iter().for_each(job));
}

/// Maps every item with `job`, spreading them across a thread pool if there are enough.
///
/// The results are in the order of `items`.
pub(crate) fn map<T: Send, U: Send>(items: Vec<T>, job: impl Fn(T) -> U + Send + Sync) -> Vec<U> {
    let Some(pool) = pool_for(items.len()) else {
        return items.into_iter().map(job).collect();
    };

    pool.install(|| items.into_par_iter().map(job).collect())
}

fn pool_for(num_jobs: usize) -> Option<&'static ThreadPool> {
    POOL.as_ref().filter(|_| num_jobs >= MIN_PARALLEL_JOBS)
}
