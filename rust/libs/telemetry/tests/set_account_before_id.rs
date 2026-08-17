use telemetry::TESTING;

#[tokio::test]
async fn set_account_slug_before_set_firezone_id_preserves_both() {
    let _ = rustls::crypto::ring::default_provider().install_default();

    telemetry::configure(std::sync::Arc::new(socket_factory::tcp));
    telemetry::start("entrypoint", "1.0.0", TESTING);

    telemetry::set_account_slug("acme".to_owned());
    telemetry::set_mdm_device_id(Some("intune-device-123".to_owned()));
    telemetry::set_account_id(Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3".to_owned()));
    telemetry::set_actor_email(Some("alice@example.com".to_owned()));
    telemetry::set_firezone_id("device-xyz".to_owned());

    assert_eq!(telemetry::current_user().as_deref(), Some("device-xyz"));
    assert_eq!(telemetry::current_account_slug().as_deref(), Some("acme"));
    assert_eq!(
        telemetry::current_account_id().as_deref(),
        Some("5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3")
    );
    assert_eq!(
        telemetry::current_actor_email().as_deref(),
        Some("alice@example.com")
    );
    assert_eq!(
        telemetry::current_mdm_device_id().as_deref(),
        Some("intune-device-123")
    );

    telemetry::set_mdm_device_id(None);
    telemetry::set_account_slug_or_clear(None);
    telemetry::set_account_id(None);
    telemetry::set_actor_email(None);
    assert_eq!(telemetry::current_mdm_device_id(), None);
    assert_eq!(telemetry::current_account_slug(), None);
    assert_eq!(telemetry::current_account_id(), None);
    assert_eq!(telemetry::current_actor_email(), None);
}
