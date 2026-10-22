use telemetry::{Env, TESTING};

#[tokio::test]
async fn stop_deactivates_but_remembers_env() {
    // No socket factory is configured, so the ingest client can never connect and
    // the tests report nothing to Sentry.
    telemetry::start("wss://api.firez.one", "1.0.0", TESTING);
    assert!(telemetry::is_active());

    telemetry::stop();

    assert!(!telemetry::is_active());
    assert_eq!(telemetry::current_env(), Some(Env::Staging));
}
