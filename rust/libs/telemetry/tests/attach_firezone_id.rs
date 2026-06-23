use telemetry::{TESTING, Telemetry};

#[tokio::test]
async fn set_firezone_id_attaches_user_to_running_session() {
    let _ = rustls::crypto::ring::default_provider().install_default();

    let mut telemetry = Telemetry::new(
        std::sync::Arc::new(socket_factory::tcp),
        std::sync::Arc::new(socket_factory::udp),
    );
    telemetry.start("entrypoint", "1.0.0", TESTING);

    Telemetry::set_firezone_id("device-abc".to_owned()).await;

    assert_eq!(Telemetry::current_user().as_deref(), Some("device-abc"));
}
