use telemetry::{TESTING, Telemetry};

#[tokio::test]
async fn set_account_slug_before_set_firezone_id_preserves_both() {
    let _ = rustls::crypto::ring::default_provider().install_default();

    let mut telemetry = Telemetry::new(
        std::sync::Arc::new(socket_factory::tcp),
        std::sync::Arc::new(socket_factory::udp),
    );
    telemetry.start("entrypoint", "1.0.0", TESTING);

    Telemetry::set_account_slug("acme".to_owned());
    Telemetry::set_firezone_id("device-xyz".to_owned()).await;

    assert_eq!(Telemetry::current_user().as_deref(), Some("device-xyz"));
    assert_eq!(Telemetry::current_account_slug().as_deref(), Some("acme"));
}
