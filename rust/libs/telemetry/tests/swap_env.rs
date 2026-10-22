use telemetry::{Env, TESTING};

#[tokio::test]
async fn entrypoint_then_real_env_swaps_running_session() {
    // No socket factory is configured, so the ingest client can never connect and
    // the tests report nothing to Sentry.
    telemetry::start("entrypoint", "1.0.0", TESTING);
    assert_eq!(telemetry::current_env(), Some(Env::Entrypoint));

    telemetry::start("wss://api.firez.one", "1.0.0", TESTING);
    assert_eq!(telemetry::current_env(), Some(Env::Staging));
}
