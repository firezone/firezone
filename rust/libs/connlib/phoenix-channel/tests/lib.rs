#![cfg(not(windows))] // For some reason, Windows doesn't like this test.
#![allow(clippy::unwrap_used)]

#[tokio::test]
async fn client_does_not_pipeline_messages() {
    use std::{str::FromStr, sync::Arc, time::Duration};

    use backoff::exponential::ExponentialBackoff;
    use futures::{SinkExt, StreamExt};
    use phoenix_channel::{DeviceInfo, LoginUrl, PhoenixChannel, PublicKeyParam};
    use secrecy::SecretString;
    use tokio::net::TcpListener;
    use tokio_tungstenite::tungstenite::Message;
    use url::Url;

    let _guard = logging::test("debug,wire::api=trace");

    let listener = TcpListener::bind("0.0.0.0:0").await.unwrap();
    let server_addr = listener.local_addr().unwrap();

    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();

        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();

        loop {
            match ws.next().await {
                Some(Ok(Message::Text(text))) => match text.as_str() {
                    r#"{"topic":"test","event":"phx_join","payload":null,"ref":1}"# => {
                        // The real Elixir backend processes messages in parallel and therefore may drop messages if we pipeline them instead of waiting for the channel join.
                        // This is difficult to assert in a test because we need to mimic this behaviour of not processing messages sequentially.
                        // The way we assert this is by checking, whether any messages are pipelined.
                        // Reading another message from the stream should timeout at this point because we haven't acknowledged the room join yet.
                        if let Ok(msg) =
                            tokio::time::timeout(Duration::from_millis(100), ws.next()).await
                        {
                            panic!("Did not yet expect another msg: {msg:?}")
                        }

                        ws.send(Message::text(
                            r#"{"event":"phx_reply","ref":1,"topic":"client","payload":{"status":"ok","response":{}}}"#,
                        )).await.unwrap();
                    }
                    r#"{"topic":"test","event":"bar","ref":0}"# => {
                        ws.send(Message::text(
                            r#"{"topic":"test","event":"foo","payload":null}"#,
                        ))
                        .await
                        .unwrap();
                    }
                    other => panic!("Unexpected message: {other}"),
                },
                Some(Ok(Message::Close(_))) => continue,
                Some(other) => {
                    panic!("Unexpected message: {other:?}")
                }
                None => break,
            }
        }
    });

    let login_url = LoginUrl::client(
        Url::from_str(&format!("ws://localhost:{}", server_addr.port())).unwrap(),
        String::new(),
        None,
        DeviceInfo::default(),
    )
    .unwrap();

    let mut channel = PhoenixChannel::<(), OutboundMsg, InboundMsg, _>::disconnected(
        login_url,
        SecretString::from("secret"),
        "test/1.0.0".to_owned(),
        "test",
        (),
        ExponentialBackoff::default,
        Arc::new(socket_factory::tcp),
    )
    .unwrap();

    let client = async move {
        channel.connect(PublicKeyParam([0u8; 32]));
        channel.send("test", OutboundMsg::Bar);

        loop {
            match std::future::poll_fn(|cx| channel.poll(cx)).await.unwrap() {
                phoenix_channel::Event::SuccessResponse { .. } => {}
                phoenix_channel::Event::ErrorResponse { res, .. } => {
                    panic!("Unexpected error: {res:?}")
                }
                phoenix_channel::Event::JoinedRoom { .. } => {}
                phoenix_channel::Event::HeartbeatSent => {}
                phoenix_channel::Event::InboundMessage {
                    msg: InboundMsg::Foo,
                    ..
                } => {
                    channel.close().unwrap();
                }
                phoenix_channel::Event::Hiccup { error, .. } => {
                    panic!("Unexpected hiccup: {error:?}")
                }
                phoenix_channel::Event::Closed => break,
            }
        }
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
async fn client_deduplicates_messages() {
    use std::{str::FromStr, sync::Arc, time::Duration};

    use backoff::exponential::ExponentialBackoff;
    use futures::{SinkExt, StreamExt};
    use phoenix_channel::{DeviceInfo, LoginUrl, PhoenixChannel, PublicKeyParam};
    use secrecy::SecretString;
    use tokio::net::TcpListener;
    use tokio_tungstenite::tungstenite::Message;
    use url::Url;

    let _guard = logging::test("debug,wire::api=trace");

    let listener = TcpListener::bind("0.0.0.0:0").await.unwrap();
    let server_addr = listener.local_addr().unwrap();

    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();

        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();

        loop {
            match ws.next().await {
                Some(Ok(Message::Text(text))) => match text.as_str() {
                    r#"{"topic":"test","event":"phx_join","payload":null,"ref":0}"# => {
                        ws.send(Message::text(
                            r#"{"event":"phx_reply","ref":0,"topic":"client","payload":{"status":"ok","response":{}}}"#,
                        )).await.unwrap();
                    }
                    // We only handle the message with `ref: 1` and thus guarantee that not more than 1 is received
                    r#"{"topic":"test","event":"bar","ref":1}"# => {
                        ws.send(Message::text(
                            r#"{"topic":"test","event":"foo","payload":null}"#,
                        ))
                        .await
                        .unwrap();
                    }
                    other => panic!("Unexpected message: {other}"),
                },
                Some(Ok(Message::Close(_))) => continue,
                Some(other) => {
                    panic!("Unexpected message: {other:?}")
                }
                None => break,
            }
        }
    });

    let login_url = LoginUrl::client(
        Url::from_str(&format!("ws://localhost:{}", server_addr.port())).unwrap(),
        String::new(),
        None,
        DeviceInfo::default(),
    )
    .unwrap();

    let mut channel = PhoenixChannel::<(), OutboundMsg, InboundMsg, _>::disconnected(
        login_url,
        SecretString::from("secret"),
        "test/1.0.0".to_owned(),
        "test",
        (),
        ExponentialBackoff::default,
        Arc::new(socket_factory::tcp),
    )
    .unwrap();

    let mut num_responses = 0;

    let client = async {
        channel.connect(PublicKeyParam([0u8; 32]));

        loop {
            match std::future::poll_fn(|cx| channel.poll(cx)).await.unwrap() {
                phoenix_channel::Event::SuccessResponse { .. } => {}
                phoenix_channel::Event::ErrorResponse { res, .. } => {
                    panic!("Unexpected error: {res:?}")
                }
                phoenix_channel::Event::JoinedRoom { .. } => {
                    channel.send("test", OutboundMsg::Bar);
                    channel.send("test", OutboundMsg::Bar);
                    channel.send("test", OutboundMsg::Bar);
                    channel.send("test", OutboundMsg::Bar);
                }
                phoenix_channel::Event::HeartbeatSent => {}
                phoenix_channel::Event::InboundMessage {
                    msg: InboundMsg::Foo,
                    ..
                } => {
                    num_responses += 1;
                }
                phoenix_channel::Event::Hiccup { error, .. } => {
                    panic!("Unexpected hiccup: {error:?}")
                }
                phoenix_channel::Event::Closed => break,
            }
        }
    };

    let _ = tokio::time::timeout(
        Duration::from_secs(2),
        futures::future::join(server, client),
    )
    .await
    .unwrap_err(); // We expect to timeout because we don't ever exit from the tasks.

    assert_eq!(num_responses, 1);
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

/// Tests that initial connection attempts use the fixed 1s interval backoff with 15s max.
#[tokio::test]
async fn initial_connection_uses_short_backoff() {
    use std::{str::FromStr, sync::Arc, time::Duration};

    use phoenix_channel::{DeviceInfo, Error, LoginUrl, PhoenixChannel, PublicKeyParam};
    use secrecy::SecretString;
    use url::Url;

    let _guard = logging::test("debug");

    // Use a port that nothing is listening on - connection will fail immediately
    let login_url = LoginUrl::client(
        Url::from_str("ws://127.0.0.1:1").unwrap(), // Port 1 is reserved, nothing should be listening
        String::new(),
        None,
        DeviceInfo::default(),
    )
    .unwrap();

    let mut channel = PhoenixChannel::<(), OutboundMsg, InboundMsg, _>::disconnected(
        login_url,
        SecretString::from("secret"),
        "test/1.0.0".to_owned(),
        "test",
        (),
        || {
            // This should NOT be used for initial connection attempts
            backoff::ExponentialBackoffBuilder::default()
                .with_max_elapsed_time(Some(Duration::from_secs(3600))) // 1 hour - way too long for initial
                .build()
        },
        Arc::new(socket_factory::tcp),
    )
    .unwrap();

    channel.connect(PublicKeyParam([0u8; 32]));

    let mut hiccups = Vec::new();
    let start = std::time::Instant::now();

    loop {
        match std::future::poll_fn(|cx| channel.poll(cx)).await {
            Ok(phoenix_channel::Event::Hiccup {
                backoff,
                max_elapsed_time,
                ..
            }) => {
                hiccups.push((backoff, max_elapsed_time));
            }
            Err(Error::MaxRetriesReached { .. }) => break,
            other => panic!("Unexpected event: {other:?}"),
        }
    }

    let elapsed = start.elapsed();

    // Should have completed within ~15s (the initial backoff max), not 1 hour
    assert!(
        elapsed < Duration::from_secs(20),
        "Expected to complete within 20s, but took {elapsed:?}"
    );

    // All hiccups should report max_elapsed_time of 15s (initial backoff)
    for (i, (backoff, max_elapsed_time)) in hiccups.iter().enumerate() {
        assert_eq!(
            *max_elapsed_time,
            Some(Duration::from_secs(15)),
            "Hiccup {i} should have max_elapsed_time of 15s for initial connection"
        );
        // First backoff is 0, subsequent ones should be ~1s
        if i > 0 {
            assert!(
                *backoff >= Duration::from_millis(900) && *backoff <= Duration::from_millis(1100),
                "Hiccup {i} backoff should be ~1s, got {backoff:?}"
            );
        }
    }
}

/// Tests that after a successful connection, reconnection attempts use the caller-provided backoff.
#[tokio::test]
async fn reconnection_uses_callers_backoff() {
    use std::{str::FromStr, sync::Arc, time::Duration};

    use futures::{SinkExt, StreamExt};
    use phoenix_channel::{DeviceInfo, LoginUrl, PhoenixChannel, PublicKeyParam};
    use secrecy::SecretString;
    use tokio::net::TcpListener;
    use tokio_tungstenite::tungstenite::Message;
    use url::Url;

    let _guard = logging::test("debug");

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let server_addr = listener.local_addr().unwrap();

    // Server that accepts one connection, sends join reply, then closes
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();

        // Wait for the join message and respond properly
        while let Some(Ok(msg)) = ws.next().await {
            if msg.is_text() {
                let text = msg.into_text().unwrap();
                if text.contains("phx_join") {
                    // Send proper join reply first
                    ws.send(Message::text(
                        r#"{"event":"phx_reply","ref":0,"topic":"test","payload":{"status":"ok","response":{}}}"#,
                    ))
                    .await
                    .unwrap();

                    // Small delay to ensure the client processes the join
                    tokio::time::sleep(Duration::from_millis(50)).await;

                    // Now close the connection
                    ws.close(None).await.ok();
                    break;
                }
            }
        }

        // Don't accept any more connections - let the client fail to reconnect
    });

    let login_url = LoginUrl::client(
        Url::from_str(&format!("ws://127.0.0.1:{}", server_addr.port())).unwrap(),
        String::new(),
        None,
        DeviceInfo::default(),
    )
    .unwrap();

    const RECONNECT_MAX_ELAPSED: Duration = Duration::from_secs(5);

    let mut channel = PhoenixChannel::<(), OutboundMsg, InboundMsg, _>::disconnected(
        login_url,
        SecretString::from("secret"),
        "test/1.0.0".to_owned(),
        "test",
        (),
        || {
            // This SHOULD be used for reconnection attempts (after successful connection)
            backoff::ExponentialBackoffBuilder::default()
                .with_max_elapsed_time(Some(RECONNECT_MAX_ELAPSED))
                .build()
        },
        Arc::new(socket_factory::tcp),
    )
    .unwrap();

    channel.connect(PublicKeyParam([0u8; 32]));

    let mut connected = false;
    let mut reconnect_hiccups = Vec::new();

    let result = tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            match std::future::poll_fn(|cx| channel.poll(cx)).await {
                Ok(phoenix_channel::Event::JoinedRoom { .. }) => {
                    connected = true;
                    // Connection succeeded, now wait for it to be dropped by the server
                }
                Ok(phoenix_channel::Event::Hiccup {
                    backoff,
                    max_elapsed_time,
                    ..
                }) => {
                    if connected {
                        // This is a reconnection attempt
                        reconnect_hiccups.push((backoff, max_elapsed_time));
                    }
                }
                Ok(phoenix_channel::Event::HeartbeatSent) => {}
                Ok(phoenix_channel::Event::SuccessResponse { .. }) => {}
                Err(phoenix_channel::Error::MaxRetriesReached { .. }) => {
                    break;
                }
                other => {
                    // Continue on other events
                    tracing::debug!(?other, "Got event");
                }
            }
        }
    })
    .await;

    server.abort();

    assert!(result.is_ok(), "Test timed out");
    assert!(connected, "Should have connected at least once");
    assert!(
        !reconnect_hiccups.is_empty(),
        "Should have had reconnection hiccups"
    );

    // All reconnection hiccups should use the caller's max_elapsed_time
    for (i, (_backoff, max_elapsed_time)) in reconnect_hiccups.iter().enumerate() {
        assert_eq!(
            *max_elapsed_time,
            Some(RECONNECT_MAX_ELAPSED),
            "Reconnection hiccup {i} should use caller's max_elapsed_time of {RECONNECT_MAX_ELAPSED:?}"
        );
    }
}
