use telemetry::{Env, TESTING, Telemetry};

#[tokio::test]
async fn entrypoint_then_real_env_swaps_running_session() {
    let _ = rustls::crypto::ring::default_provider().install_default();

    let mut telemetry = Telemetry::new();
    telemetry.start("entrypoint", "1.0.0", TESTING);
    assert_eq!(Telemetry::current_env(), Some(Env::Entrypoint));

    telemetry.start("wss://api.firez.one", "1.0.0", TESTING);
    assert_eq!(Telemetry::current_env(), Some(Env::Staging));
}
