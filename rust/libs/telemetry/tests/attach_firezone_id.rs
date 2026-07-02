use telemetry::TESTING;

#[tokio::test]
async fn set_firezone_id_attaches_user_to_running_session() {
    let _ = rustls::crypto::ring::default_provider().install_default();

    telemetry::configure(
        std::sync::Arc::new(socket_factory::tcp),
        std::sync::Arc::new(socket_factory::udp),
    );
    telemetry::start("entrypoint", "1.0.0", TESTING);

    telemetry::set_firezone_id("device-abc".to_owned());

    assert_eq!(telemetry::current_user().as_deref(), Some("device-abc"));
}
