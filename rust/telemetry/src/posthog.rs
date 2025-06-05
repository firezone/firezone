use std::sync::LazyLock;
use tokio::runtime::Runtime;

use crate::Env;

pub(crate) const POSTHOG_API_KEY_PROD: &str = "phc_uXXl56plyvIBHj81WwXBLtdPElIRbm7keRTdUCmk8ll";
pub(crate) const POSTHOG_API_KEY_STAGING: &str = "phc_tHOVtq183RpfKmzadJb4bxNpLM5jzeeb1Gu8YSH3nsK";
pub(crate) const POSTHOG_API_KEY_ON_PREM: &str = "phc_4R9Ii6q4SEofVkH7LvajwuJ3nsGFhCj0ZlfysS2FNc";

pub(crate) static RUNTIME: LazyLock<Runtime> = LazyLock::new(init_runtime);

pub(crate) fn api_key_for_env(env: Env) -> &'static str {
    match env {
        Env::Production => POSTHOG_API_KEY_PROD,
        Env::Staging => POSTHOG_API_KEY_STAGING,
        Env::OnPrem => POSTHOG_API_KEY_ON_PREM,
    }
}

/// Initialize the runtime to use for evaluating feature flags.
fn init_runtime() -> Runtime {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1) // We only need 1 worker thread.
        .thread_name("posthog-worker")
        .enable_io()
        .enable_time()
        .build()
        .expect("to be able to build runtime");

    runtime.spawn(crate::feature_flags::reeval_timer());

    runtime
}
