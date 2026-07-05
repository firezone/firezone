use telemetry::{Env, TESTING};

#[tokio::test]
async fn start_on_other_thread_swaps_env_on_main_hub() {
    let _ = rustls::crypto::ring::default_provider().install_default();

    telemetry::configure(
        std::sync::Arc::new(socket_factory::tcp),
        std::sync::Arc::new(socket_factory::udp),
    );
    telemetry::start("entrypoint", "1.0.0", TESTING);
    assert_eq!(telemetry::current_env(), Some(Env::Entrypoint));

    std::thread::spawn(|| telemetry::start("wss://api.firezone.dev", "1.0.0", TESTING))
        .join()
        .expect("`start` should not panic");

    assert_eq!(telemetry::current_env(), Some(Env::Production));
}
