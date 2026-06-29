use telemetry::{TESTING, Telemetry};

#[tokio::test]
async fn starting_session_for_unsupported_env_disables_current_one() {
    let _ = rustls::crypto::ring::default_provider().install_default();

    let mut telemetry = Telemetry::new(
        std::sync::Arc::new(socket_factory::tcp),
        std::sync::Arc::new(socket_factory::udp),
    );
    telemetry.start("wss://api.firez.one", "1.0.0", TESTING);
    telemetry.start("wss://example.com", "1.0.0", TESTING);

    assert!(!telemetry.is_active());
}
