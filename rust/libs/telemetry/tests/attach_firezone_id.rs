use telemetry::TESTING;

#[tokio::test]
async fn set_firezone_id_attaches_user_to_running_session() {
    // No socket factory is configured, so the ingest client can never connect and
    // the tests report nothing to Sentry.
    telemetry::start("entrypoint", "1.0.0", TESTING);

    telemetry::set_firezone_id("device-abc".to_owned());

    assert_eq!(telemetry::current_user().as_deref(), Some("device-abc"));
}
