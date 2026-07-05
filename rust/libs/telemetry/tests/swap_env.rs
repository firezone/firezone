use telemetry::{Env, TESTING};

#[tokio::test]
async fn entrypoint_then_real_env_swaps_running_session() {
    let _ = rustls::crypto::ring::default_provider().install_default();

    tunnel_bypass_resolver::configure(
        std::sync::Arc::new(socket_factory::tcp),
        std::sync::Arc::new(socket_factory::udp),
    );
    telemetry::start("entrypoint", "1.0.0", TESTING);
    assert_eq!(telemetry::current_env(), Some(Env::Entrypoint));

    telemetry::start("wss://api.firez.one", "1.0.0", TESTING);
    assert_eq!(telemetry::current_env(), Some(Env::Staging));
}
