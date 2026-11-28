#![cfg(not(windows))] // For some reason, Windows doesn't like this test.
#![allow(clippy::unwrap_used)]

use std::future;
use std::net::{IpAddr, Ipv4Addr};
use std::pin::pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use futures::future::Either;
use futures::{SinkExt, StreamExt as _};
use phoenix_channel::{DeviceInfo, Error, Event, LoginUrl, PhoenixChannel, PublicKeyParam};
use secrecy::SecretString;
use test_case::test_case;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::TcpListener;
use tokio::task::JoinError;
use tokio_tungstenite::tungstenite::{Message, http};

#[tokio::test]
async fn sends_messages_without_joining() {
    let _guard = logging::test("debug,wire::api=trace");

    let (server, port) = spawn_echo_server().await;
    let mut channel = make_test_channel("localhost", port, default_backoff);

    let client = async move {
        connect(&mut channel, Duration::ZERO);
        poll_until_connected(&mut channel).await;

        // The first frame the server sees is the message itself.
        channel.send(OutboundMsg::Bar).unwrap();
        next_message(&mut channel).await;

        channel.close().unwrap();
        poll_until_closed(&mut channel).await;
    };

    tokio::time::timeout(Duration::from_secs(2), client)
        .await
        .unwrap();
    server.wait().await;
}

#[tokio::test]
#[expect(
    clippy::result_large_err,
    reason = "The header callback of `accept_hdr_async` returns tungstenite's response type"
)]
async fn sends_secret_headers_with_the_upgrade_request() {
    let _guard = logging::test("debug,wire::api=trace");

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();

    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut stamp_secret = None;

        let _ws =
            tokio_tungstenite::accept_hdr_async(stream, |request: &http::Request<()>, response| {
                stamp_secret = request
                    .headers()
                    .get("X-Stamp-Secret")
                    .map(|value| value.to_str().unwrap().to_owned());

                Ok(response)
            })
            .await
            .unwrap();

        stamp_secret
    });

    let mut channel = make_test_channel("127.0.0.1", port, default_backoff)
        .with_header("X-Stamp-Secret", SecretString::from("secret"));
    connect(&mut channel, Duration::ZERO);
    poll_until_connected(&mut channel).await;

    assert_eq!(server.await.unwrap().as_deref(), Some("secret"));
}

#[tokio::test]
async fn token_expired_disconnect_requires_sign_in() {
    let _guard = logging::test("debug,wire::api=trace");

    let (server, port) = spawn_websocket_server(|text| match text {
        BAR_REQUEST => r#"{"event":"disconnect","payload":{"reason":"token_expired"}}"#,
        other => panic!("Unexpected message: {other}"),
    })
    .await;
    let mut channel = make_test_channel("127.0.0.1", port, default_backoff);

    connect(&mut channel, Duration::ZERO);
    poll_until_connected(&mut channel).await;
    channel.send(OutboundMsg::Bar).unwrap();

    let error = future::poll_fn(|cx| channel.poll(cx)).await.unwrap_err();

    assert!(error.requires_sign_in(), "got {error:?}");
    server.abort();
}

#[tokio::test]
async fn client_deduplicates_messages() {
    let _guard = logging::test("debug,wire::api=trace");

    let (server, port) = spawn_echo_server().await;
    let mut channel = make_test_channel("localhost", port, default_backoff);

    let mut num_responses = 0;

    let client = async {
        connect(&mut channel, Duration::ZERO);
        poll_until_connected(&mut channel).await;

        for _ in 0..4 {
            channel.send(OutboundMsg::Bar).unwrap();
        }

        loop {
            next_message(&mut channel).await;
            num_responses += 1;
        }
    };

    let _ = tokio::time::timeout(
        Duration::from_secs(2),
        futures::future::join(server.wait(), client),
    )
    .await
    .unwrap_err(); // We expect to timeout because we don't ever exit from the tasks.

    assert_eq!(num_responses, 1);
}

#[tokio::test]
async fn client_clears_local_message_on_connect() {
    let _guard = logging::test("debug,wire::api=trace");

    let num_bars = Arc::new(AtomicUsize::default());
    let (server, port) = spawn_websocket_server({
        let num_bars = num_bars.clone();

        move |text| match text {
            BAR_REQUEST => {
                num_bars.fetch_add(1, Ordering::SeqCst);
                FOO_MESSAGE
            }
            other => panic!("Unexpected message: {other}"),
        }
    })
    .await;
    let mut channel = make_test_channel("localhost", port, default_backoff);

    let client = async {
        // A message sent while disconnected must not be buffered and sent on connect.
        channel.send(OutboundMsg::Bar).unwrap_err();

        connect(&mut channel, Duration::ZERO);
        poll_until_connected(&mut channel).await;

        channel.send(OutboundMsg::Bar).unwrap();
        next_message(&mut channel).await;

        channel.close().unwrap();
        poll_until_closed(&mut channel).await;
    };

    client.await;
    server.wait().await;

    assert_eq!(num_bars.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn ignores_unknown_messages() {
    let _guard = logging::test("debug,wire::api=trace");

    let listener = TcpListener::bind("0.0.0.0:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();

    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();

        loop {
            match ws.next().await {
                Some(Ok(Message::Text(text))) => match text.as_str() {
                    BAR_REQUEST => {
                        ws.send(Message::text(UNKNOWN_MESSAGE)).await.unwrap();
                        ws.send(Message::text(FOO_MESSAGE)).await.unwrap();
                    }
                    other => panic!("Unexpected message: {other}"),
                },
                Some(Ok(Message::Close(_) | Message::Ping(_))) => continue,
                Some(other) => panic!("Unexpected message: {other:?}"),
                None => break,
            }
        }
    });

    let mut channel = make_test_channel("localhost", port, default_backoff);

    let client = async move {
        connect(&mut channel, Duration::ZERO);
        poll_until_connected(&mut channel).await;

        channel.send(OutboundMsg::Bar).unwrap();
        let msg = next_message(&mut channel).await;
        assert!(matches!(msg, InboundMsg::Foo));

        channel.close().unwrap();
        poll_until_closed(&mut channel).await;
    };

    let (join_res, _) = tokio::time::timeout(
        Duration::from_secs(2),
        futures::future::join(server, client),
    )
    .await
    .unwrap();
    join_res.unwrap();
}

#[tokio::test]
async fn replies_with_close_frame_upon_close() {
    let _guard = logging::test("debug,wire::api=trace");

    let (server, port) = spawn_idle_server().await;
    let mut channel = make_test_channel("localhost", port, default_backoff);

    let (mut connected_tx, mut connected_rx) = futures::channel::mpsc::channel(1);

    let client = tokio::spawn(async move {
        connect(&mut channel, Duration::ZERO);
        poll_until_connected(&mut channel).await;
        connected_tx.send(()).await.unwrap();

        poll_until_hiccup(&mut channel).await.error
    });

    connected_rx.recv().await.unwrap(); // Wait for successful connection.

    let server_result = server.stop().await;
    let client_error = client.await.unwrap();

    server_result.unwrap(); // Server should shutdown cleanly.

    assert_eq!(
        client_error,
        "Connection hiccup: portal sent empty websocket close frame"
    );
}

#[tokio::test]
async fn times_out_after_unanswered_pings() {
    let _guard = logging::test("debug,wire::api=trace");

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();

    // A server that never reads, so it never answers the pings.
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let _ws = tokio_tungstenite::accept_async(stream).await.unwrap();

        future::pending::<()>().await;
    });

    let mut channel = make_test_channel("localhost", port, default_backoff);

    connect(&mut channel, Duration::ZERO);
    poll_until_connected(&mut channel).await;
    let error = poll_until_hiccup(&mut channel).await.error;

    server.abort();

    assert_eq!(error, "Connection hiccup: too many pings were unanswered");
}

#[tokio::test]
async fn keeps_pinging_while_the_portal_answers() {
    let _guard = logging::test("debug,wire::api=trace");

    let num_pings = Arc::new(AtomicUsize::default());

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();

    let server = tokio::spawn({
        let num_pings = num_pings.clone();

        async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();

            // Reading answers each ping with a pong.
            while let Some(Ok(message)) = ws.next().await {
                match message {
                    Message::Ping(_) => {
                        num_pings.fetch_add(1, Ordering::SeqCst);
                    }
                    Message::Text(text) if text.as_str() == BAR_REQUEST => {
                        ws.send(Message::text(FOO_MESSAGE)).await.unwrap();
                    }
                    other @ (Message::Text(_)
                    | Message::Binary(_)
                    | Message::Pong(_)
                    | Message::Close(_)
                    | Message::Frame(_)) => panic!("Unexpected message: {other:?}"),
                }
            }
        }
    });

    let mut channel = make_test_channel("localhost", port, default_backoff);

    let client = tokio::spawn(async move {
        connect(&mut channel, Duration::ZERO);

        let mut message_interval = tokio::time::interval(Duration::from_secs(3));

        loop {
            // Scoped so that the borrow of `channel` ends before we send on it.
            let event = {
                let event = pin!(future::poll_fn(|cx| channel.poll(cx)));
                let tick = pin!(message_interval.tick());

                match futures::future::select(event, tick).await {
                    Either::Left((event, _)) => Some(event),
                    Either::Right((_, _)) => None,
                }
            };

            let Some(event) = event else {
                let _ = channel.send(OutboundMsg::Bar);
                continue;
            };

            match event.unwrap() {
                Event::Message { .. } => {}
                Event::Connected => {}
                Event::Closed => panic!("Channel closed"),
                Event::Hiccup { error, .. } => panic!("Connection failed: {error:#}"),
            }
        }
    });

    // More pings than `MAX_UNANSWERED_PINGS`: the pongs keep the connection up.
    tokio::time::sleep(Duration::from_secs(45)).await;

    assert_eq!(num_pings.load(Ordering::SeqCst), 4);

    client.abort();
    server.abort();
}

#[tokio::test]
async fn includes_ip_from_hostname() {
    let _guard = logging::test("debug,wire::api=trace");

    let (server, port) = spawn_idle_server().await;
    let mut channel = make_test_channel("127.0.0.1", port, default_backoff);

    // Without any IPs, the channel has to resolve them from the URL's host itself.
    channel.connect(vec![], Duration::ZERO, PublicKeyParam([0u8; 32]));
    poll_until_connected(&mut channel).await;

    server.abort();
}

#[tokio::test]
async fn initial_connection_uses_constant_1s_backoff() {
    let _guard = logging::test("debug");

    let mut channel = make_test_channel("127.0.0.1", 1, default_backoff);
    connect(&mut channel, Duration::ZERO);

    let start = std::time::Instant::now();

    loop {
        match future::poll_fn(|cx| channel.poll(cx)).await {
            Ok(Event::Hiccup {
                backoff,
                max_elapsed_time,
                ..
            }) => {
                assert_eq!(max_elapsed_time, Some(Duration::from_secs(15)));
                assert_eq!(backoff, Duration::from_secs(1));

                connect(&mut channel, backoff);
            }
            Err(Error::MaxRetriesReached { .. }) => break,
            other => panic!("Unexpected event: {other:?}"),
        }
    }

    let elapsed = start.elapsed();

    assert!(
        elapsed < Duration::from_secs(20),
        "Expected to complete within 20s, but took {elapsed:?}"
    );
}

#[tokio::test]
async fn connect_with_zero_backoff_resets_reconnect_backoff() {
    let _guard = logging::test("debug");

    let (server, port) = spawn_idle_server().await;
    let mut channel = make_test_channel("127.0.0.1", port, fast_backoff);

    tokio::time::timeout(Duration::from_secs(10), async {
        // Connect once, then drop the server so every reconnect afterwards fails.
        connect(&mut channel, Duration::ZERO);
        poll_until_connected(&mut channel).await;
        server.abort();

        // Let the backoff grow by reconnecting with the suggested backoff.
        let first = poll_until_hiccup(&mut channel).await.backoff;
        connect(&mut channel, first);
        let grown = poll_until_hiccup(&mut channel).await.backoff;
        assert!(grown > first, "backoff should grow on consecutive hiccups");

        // A zero-backoff `connect` resets the backoff, so the next hiccup starts
        // over at the initial interval instead of continuing from `grown`.
        connect(&mut channel, Duration::ZERO);
        let reset = poll_until_hiccup(&mut channel).await.backoff;
        assert_eq!(
            reset, first,
            "zero-backoff connect should reset the backoff"
        );
    })
    .await
    .expect("should not timeout");
}

// The portal names permanent rejections with a problem code; the HTTP status only decides
// for a response that carries no code the client knows.
#[test_case(r#"{"status":401,"detail":"Invalid token","code":"invalid_token"}"# => "Your Firezone sign-in has expired. Sign in again to reconnect."; "an unusable token")]
#[test_case(r#"{"status":401,"detail":"No token","code":"missing_token"}"# => "Your Firezone sign-in has expired. Sign in again to reconnect."; "a missing token")]
#[test_case(r#"{"status":403,"detail":"This device's certificate has been revoked.","code":"certificate_revoked"}"# => "This device's certificate has been revoked."; "a revoked certificate")]
#[test_case(r#"{"status":403,"detail":"This device is not trusted.","code":"device_untrusted"}"# => "This device is not trusted."; "an untrusted device")]
#[test_case(r#"{"status":409,"detail":"Different hardware.","code":"device_identity_conflict"}"# => "Different hardware."; "a conflicting device identity")]
#[test_case(r#"{"status":403,"detail":"This device's certificate does not identify an active user authorized to access this Firezone account. Please contact your administrator.","code":"x509_user_not_authorized"}"# => "This device's certificate does not identify an active user authorized to access this Firezone account. Please contact your administrator."; "an unauthorized X.509 user")]
#[test_case(r#"{"status":403,"detail":"Incomplete identity.","code":"invalid_x509_identity"}"# => "Incomplete identity."; "invalid X.509 identity claims")]
#[test_case(r#"{"status":403,"detail":"Provider disabled.","code":"x509_authentication_disabled"}"# => "Provider disabled."; "a disabled X.509 provider")]
#[test_case(r#"{"status":403,"detail":"No trust anchors.","code":"no_trust_anchors"}"# => "No trust anchors."; "missing X.509 trust anchors")]
#[test_case(r#"{"status":403,"detail":"Unknown user.","code":"x509_user_not_found"}"# => "Unknown user."; "an unknown X.509 user")]
#[test_case(r#"{"status":401,"detail":"Invalid token"}"# => "The Firezone Portal rejected this device's sign-in: Invalid token"; "a 401 without a code")]
#[test_case(r#"{"status":401}"# => "The Firezone Portal rejected this device's sign-in: no reason provided"; "a 401 without a detail")]
#[tokio::test]
async fn portal_rejection_is_terminal(problem_details: &str) -> String {
    let port = http_problem_details_server(problem_details).await;

    // Without the terminal path these are an `Event::Hiccup` and the poll never resolves, so
    // reaching the timeout is the failure this test is really guarding against.
    let error = expect_error(first_event(port).await);

    error.to_string()
}

#[test_case(r#"{"status":403,"detail":"The account is disabled","code":"account_disabled"}"#; "a code that names neither the token nor the certificate")]
#[test_case(r#"{"status":403,"detail":"Something new","code":"a_code_from_a_newer_portal"}"#; "a code the client does not know")]
#[tokio::test]
async fn portal_rejection_is_retried(problem_details: &str) {
    let port = http_problem_details_server(problem_details).await;

    expect_hiccup(first_event(port).await);
}

// An intermediary rejects the upgrade without problem details, e.g. with an error page.
#[test_case(http::StatusCode::BAD_REQUEST; "400")]
#[test_case(http::StatusCode::FORBIDDEN; "403")]
#[test_case(http::StatusCode::REQUEST_TIMEOUT; "408")]
#[test_case(http::StatusCode::TOO_MANY_REQUESTS; "429")]
#[test_case(http::StatusCode::SERVICE_UNAVAILABLE; "503")]
#[tokio::test]
async fn bare_rejection_is_retried(code: http::StatusCode) {
    let port = http_status_server(code).await;

    expect_hiccup(first_event(port).await);
}

#[tokio::test]
async fn bare_401_is_terminal() {
    let port = http_status_server(http::StatusCode::UNAUTHORIZED).await;

    let error = expect_error(first_event(port).await);

    assert_eq!(
        error.to_string(),
        "The Firezone Portal rejected this device's sign-in: no reason provided"
    );
}

#[test_case(http::StatusCode::TOO_MANY_REQUESTS, Duration::from_secs(30); "429")]
#[test_case(http::StatusCode::SERVICE_UNAVAILABLE, Duration::from_secs(60); "503")]
#[tokio::test]
async fn retry_after_header_sets_the_backoff(code: http::StatusCode, retry_after: Duration) {
    let port = http_status_server_with_retry_after(code, retry_after).await;

    let backoff = expect_hiccup(first_event(port).await);

    assert_eq!(backoff, retry_after);
}

#[test_case(r#"{"status":403,"detail":"This device's certificate has been revoked.","code":"certificate_revoked"}"#; "a revoked certificate")]
#[test_case(r#"{"status":403,"detail":"No authorized user.","code":"x509_user_not_authorized"}"#; "an unauthorized X.509 user")]
#[tokio::test]
async fn rejected_certificate_does_not_require_sign_in(problem_details: &str) {
    let port = http_problem_details_server(problem_details).await;

    let error = expect_error(first_event(port).await);

    // A new token cannot replace the credential the portal refused.
    assert!(!error.requires_sign_in());
}

/// Connects the channel to localhost after waiting for `backoff`.
fn connect(channel: &mut TestChannel, backoff: Duration) {
    channel.connect(
        vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
        backoff,
        PublicKeyParam([0u8; 32]),
    );
}

/// Polls the channel until it is connected, panicking on any other event.
async fn poll_until_connected(channel: &mut TestChannel) {
    loop {
        match future::poll_fn(|cx| channel.poll(cx)).await.unwrap() {
            Event::Connected => return,
            Event::Message { .. } => {}
            Event::Closed => panic!("Channel closed"),
            Event::Hiccup { error, .. } => panic!("Unexpected hiccup: {error:#}"),
        }
    }
}

/// Polls the channel for the next message, panicking on any other event.
async fn next_message(channel: &mut TestChannel) -> InboundMsg {
    match future::poll_fn(|cx| channel.poll(cx)).await.unwrap() {
        Event::Message { msg, .. } => msg,
        Event::Connected => panic!("Channel re-connected"),
        Event::Closed => panic!("Channel closed"),
        Event::Hiccup { error, .. } => panic!("Unexpected hiccup: {error:#}"),
    }
}

/// Polls the channel until it is closed, panicking on any other event.
async fn poll_until_closed(channel: &mut TestChannel) {
    loop {
        match future::poll_fn(|cx| channel.poll(cx)).await.unwrap() {
            Event::Closed => return,
            Event::Message { .. } => {}
            Event::Connected => panic!("Channel re-connected"),
            Event::Hiccup { error, .. } => panic!("Unexpected hiccup: {error:#}"),
        }
    }
}

/// Polls the channel until the connection hiccups, panicking on any other event.
async fn poll_until_hiccup(channel: &mut TestChannel) -> Hiccup {
    loop {
        match future::poll_fn(|cx| channel.poll(cx)).await.unwrap() {
            Event::Hiccup { backoff, error, .. } => {
                return Hiccup {
                    backoff,
                    error: format!("{error:#}"),
                };
            }
            Event::Message { .. } => {}
            Event::Connected => panic!("Channel re-connected"),
            Event::Closed => panic!("Channel closed"),
        }
    }
}

struct Hiccup {
    backoff: Duration,
    /// The error's chain of causes, as rendered by its alternate `Display` representation.
    error: String,
}

/// Connects a channel to `port` and returns the first event it emits.
///
/// # Panics
///
/// Panics if the channel does not emit an event within 5 seconds.
async fn first_event(port: u16) -> Result<Event<InboundMsg>, Error> {
    let mut channel = make_test_channel("127.0.0.1", port, default_backoff);
    connect(&mut channel, Duration::ZERO);

    tokio::time::timeout(
        Duration::from_secs(5),
        future::poll_fn(|cx| channel.poll(cx)),
    )
    .await
    .expect("should not timeout")
}

/// Asserts that the channel wants to retry and returns the backoff it suggests.
#[track_caller]
fn expect_hiccup(event: Result<Event<InboundMsg>, Error>) -> Duration {
    match event {
        Ok(Event::Hiccup { backoff, .. }) => backoff,
        other => panic!("Expected `Event::Hiccup`, got {other:?}"),
    }
}

/// Asserts that the channel failed terminally and returns the error.
#[track_caller]
fn expect_error(event: Result<Event<InboundMsg>, Error>) -> Error {
    match event {
        Err(error) => error,
        Ok(other) => panic!("Expected an error, got {other:?}"),
    }
}

type TestChannel = PhoenixChannel<OutboundMsg, InboundMsg, PublicKeyParam>;

fn make_test_channel(
    host: &str,
    port: u16,
    make_reconnect_backoff: impl Fn() -> backoff::ExponentialBackoff + Send + 'static,
) -> TestChannel {
    let url = LoginUrl::client(
        format!("ws://{host}:{port}").as_str(),
        "test-device-id".to_string(),
        Some("test-device".to_string()),
        DeviceInfo::default(),
        None,
    )
    .unwrap();

    PhoenixChannel::disconnected(
        url,
        SecretString::from("test_token"),
        "test-user-agent".to_string(),
        make_reconnect_backoff,
        Arc::new(socket_factory::tcp),
    )
}

/// The reconnect backoff used by most tests.
fn default_backoff() -> backoff::ExponentialBackoff {
    backoff::ExponentialBackoffBuilder::new()
        .with_initial_interval(Duration::from_secs(1))
        .with_max_elapsed_time(Some(Duration::from_secs(60)))
        .build()
}

/// A deterministic, fast-growing reconnect backoff: 10ms, 20ms, 40ms, ...
fn fast_backoff() -> backoff::ExponentialBackoff {
    backoff::ExponentialBackoffBuilder::new()
        .with_initial_interval(Duration::from_millis(10))
        .with_multiplier(2.0)
        .with_randomization_factor(0.0)
        .with_max_elapsed_time(Some(Duration::from_secs(60)))
        .build()
}

#[derive(serde::Serialize, serde::Deserialize, Debug)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
enum InboundMsg {
    Foo,
}

#[derive(serde::Serialize, serde::Deserialize, Debug, PartialEq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
enum OutboundMsg {
    Bar,
}

const BAR_REQUEST: &str = r#"{"event":"bar"}"#;
const FOO_MESSAGE: &str = r#"{"event":"foo","payload":null}"#;
/// A message with an event the channel does not know.
const UNKNOWN_MESSAGE: &str = r#"{"event":"unknown_event","payload":{"foo":"bar"}}"#;

/// Spawns a WebSocket server that accepts the connection and expects no messages.
async fn spawn_idle_server() -> (ServerHandle, u16) {
    spawn_websocket_server(|text| -> &'static str { panic!("Unexpected message: {text}") }).await
}

/// Spawns a WebSocket server that answers each [`OutboundMsg::Bar`] with [`InboundMsg::Foo`].
async fn spawn_echo_server() -> (ServerHandle, u16) {
    spawn_websocket_server(|text| match text {
        BAR_REQUEST => FOO_MESSAGE,
        other => panic!("Unexpected message: {other}"),
    })
    .await
}

/// Spawns a WebSocket server that responds to requests using a handler function.
/// Returns the server task handle and the port number.
async fn spawn_websocket_server<F, R>(handler: F) -> (ServerHandle, u16)
where
    F: Fn(&str) -> R + Send + 'static,
    R: Into<tokio_tungstenite::tungstenite::Utf8Bytes>,
{
    let listener = TcpListener::bind("0.0.0.0:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (close_tx, mut close_rx) = futures::channel::mpsc::channel(1);

    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();

        loop {
            match futures::future::select(ws.next(), close_rx.recv()).await {
                Either::Left((Some(Ok(Message::Text(text))), _)) => {
                    let response = handler(text.as_str());
                    ws.send(Message::text(response)).await.unwrap();
                }
                Either::Left((Some(Ok(Message::Close(_) | Message::Ping(_))), _)) => continue,
                Either::Left((Some(other), _)) => panic!("Unexpected message: {other:?}"),
                Either::Left((None, _)) => break,
                Either::Right((Err(_), _)) => continue,
                Either::Right((Ok(()), _)) => {
                    ws.close(None).await.unwrap();
                    ws.flush().await.unwrap();
                    SinkExt::close(&mut ws).await.unwrap();
                }
            }
        }
    });

    (
        ServerHandle {
            task: server,
            close_tx,
        },
        port,
    )
}

struct ServerHandle {
    task: tokio::task::JoinHandle<()>,
    close_tx: futures::channel::mpsc::Sender<()>,
}

impl ServerHandle {
    async fn stop(mut self) -> Result<(), JoinError> {
        let _ = self.close_tx.send(()).await;

        self.task.await
    }

    async fn wait(self) {
        self.task.await.unwrap()
    }

    fn abort(self) {
        self.task.abort();
    }
}

/// Spawns a server that rejects the WebSocket upgrade with the given status code.
async fn http_status_server(code: http::StatusCode) -> u16 {
    http_response_server(format!(
        "HTTP/1.1 {status} {reason}\r\n\
         Connection: close\r\n\
         Content-Type: text/plain\r\n\
         Content-Length: 0\r\n\r\n",
        status = code.as_u16(),
        reason = code.canonical_reason().unwrap_or_default()
    ))
    .await
}

/// Spawns a server that rejects the WebSocket upgrade and asks to retry after the given delay.
async fn http_status_server_with_retry_after(code: http::StatusCode, retry_after: Duration) -> u16 {
    http_response_server(format!(
        "HTTP/1.1 {status} {reason}\r\n\
         Connection: close\r\n\
         Content-Type: text/plain\r\n\
         Retry-After: {retry_after}\r\n\
         Content-Length: 0\r\n\r\n",
        status = code.as_u16(),
        reason = code.canonical_reason().unwrap_or_default(),
        retry_after = retry_after.as_secs()
    ))
    .await
}

/// Spawns a server that rejects the WebSocket upgrade with RFC 9457 problem details.
///
/// The status line is taken from the body's `status` member, so a case cannot state one
/// status in the response and another in the problem details.
async fn http_problem_details_server(problem_details: &str) -> u16 {
    let status = serde_json::from_str::<serde_json::Value>(problem_details).unwrap()["status"]
        .as_u64()
        .expect("problem details to carry a `status` member");
    let code = http::StatusCode::from_u16(status.try_into().unwrap()).unwrap();

    http_response_server(format!(
        "HTTP/1.1 {status} {reason}\r\n\
         Connection: close\r\n\
         Content-Type: application/problem+json; charset=utf-8\r\n\
         Content-Length: {length}\r\n\r\n\
         {problem_details}",
        status = code.as_u16(),
        reason = code.canonical_reason().unwrap_or_default(),
        length = problem_details.len()
    ))
    .await
}

/// Spawns a server that answers every request with the given raw HTTP response.
async fn http_response_server(response: String) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();

    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let response = response.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 4096];
                let mut total_read = 0;
                loop {
                    match tokio::time::timeout(
                        Duration::from_millis(500),
                        socket.read(&mut buf[total_read..]),
                    )
                    .await
                    {
                        Ok(Ok(0)) => break,
                        Ok(Ok(n)) => {
                            total_read += n;
                            if buf[..total_read].windows(4).any(|w| w == b"\r\n\r\n") {
                                break;
                            }
                        }
                        _ => break,
                    }
                }

                let _ = socket.write_all(response.as_bytes()).await;
                let _ = socket.flush().await;
                let _ = socket.shutdown().await;
            });
        }
    });

    port
}
