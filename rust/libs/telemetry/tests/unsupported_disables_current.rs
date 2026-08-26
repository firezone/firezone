use telemetry::TESTING;

#[tokio::test]
async fn starting_session_for_unsupported_env_disables_current_one() {
    // No socket factory is configured, so the ingest client can never connect and
    // the tests report nothing to Sentry.
    telemetry::start("wss://api.firez.one", "1.0.0", TESTING);
    telemetry::start("wss://example.com", "1.0.0", TESTING);

    assert!(!telemetry::is_active());
}
