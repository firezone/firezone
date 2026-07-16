use telemetry::{Env, TESTING};

#[tokio::test]
async fn stop_deactivates_but_remembers_env() {
    let _ = rustls::crypto::ring::default_provider().install_default();

    telemetry::configure(std::sync::Arc::new(socket_factory::tcp));
    telemetry::start("wss://api.firez.one", "1.0.0", TESTING);
    assert!(telemetry::is_active());

    telemetry::stop();

    assert!(!telemetry::is_active());
    assert_eq!(telemetry::current_env(), Some(Env::Staging));
}
