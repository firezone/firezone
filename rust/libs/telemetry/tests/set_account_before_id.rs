use telemetry::TESTING;

#[tokio::test]
async fn set_account_slug_before_set_firezone_id_preserves_both() {
    let _ = rustls::crypto::ring::default_provider().install_default();

    tunnel_bypass_resolver::configure(
        std::sync::Arc::new(socket_factory::tcp),
        std::sync::Arc::new(socket_factory::udp),
    );
    telemetry::start("entrypoint", "1.0.0", TESTING);

    telemetry::set_account_slug("acme".to_owned());
    telemetry::set_firezone_id("device-xyz".to_owned());

    assert_eq!(telemetry::current_user().as_deref(), Some("device-xyz"));
    assert_eq!(telemetry::current_account_slug().as_deref(), Some("acme"));
}
