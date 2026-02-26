#![cfg(not(windows))] // For some reason, Windows doesn't like this test.
#![allow(clippy::unwrap_used)]

use std::net::{IpAddr, Ipv4Addr};
use std::sync::atomic::AtomicUsize;
use std::{future, sync::Arc, time::Duration};

use futures::SinkExt as _;
use phoenix_channel::{DeviceInfo, Event, LoginUrl, PhoenixChannel, PublicKeyParam};
use secrecy::SecretString;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;
use tokio::task::JoinError;
use tokio_tungstenite::tungstenite::http;

#[tokio::test]
async fn client_does_not_pipeline_messages() {
    use std::time::Duration;

    use futures::{SinkExt, StreamExt};
    use phoenix_channel::PublicKeyParam;
    use tokio::net::TcpListener;
    use tokio_tungstenite::tungstenite::Message;

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
                            r#"{"event":"phx_reply","ref":0,"topic":"test","payload":{"status":"ok","response":{}}}"#,
                        )).await.unwrap();
                    }
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

    let mut channel = make_test_channel("localhost", server_addr.port());

    let client = async move {
        channel.connect(
            vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
            Duration::ZERO,
            PublicKeyParam([0u8; 32]),
        );

        loop {
            match std::future::poll_fn(|cx| channel.poll(cx)).await.unwrap() {
                phoenix_channel::Event::Message {
                    msg: InboundMsg::Foo,
                    ..
                } => {
                    channel.close().unwrap();
                }
                phoenix_channel::Event::Hiccup { error, .. } => {
                    panic!("Unexpected hiccup: {error:?}")
                }
                phoenix_channel::Event::Closed => break,
                phoenix_channel::Event::Connected => {
                    channel.send("test", OutboundMsg::Bar).unwrap();
                }
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
    use std::time::Duration;

    use phoenix_channel::PublicKeyParam;

    let _guard = logging::test("debug,wire::api=trace");

    let (server, port) = spawn_websocket_server(|text| {
        match text {
            r#"{"topic":"test","event":"phx_join","payload":null,"ref":0}"# => {
                r#"{"event":"phx_reply","ref":0,"topic":"test","payload":{"status":"ok","response":{}}}"#
            }
            // We only handle the message with `ref: 1` and thus guarantee that not more than 1 is received
            r#"{"topic":"test","event":"bar","ref":1}"# => {
                r#"{"topic":"test","event":"foo","payload":null}"#
            }
            other => panic!("Unexpected message: {other}"),
        }
    })
    .await;

    let mut channel = make_test_channel("localhost", port);

    let mut num_responses = 0;

    let client = async {
        channel.connect(
            vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
            Duration::ZERO,
            PublicKeyParam([0u8; 32]),
        );

        loop {
            match std::future::poll_fn(|cx| channel.poll(cx)).await.unwrap() {
                phoenix_channel::Event::Message {
                    msg: InboundMsg::Foo,
                    ..
                } => {
                    num_responses += 1;
                }
                phoenix_channel::Event::Hiccup { error, .. } => {
                    panic!("Unexpected hiccup: {error:?}")
                }
                phoenix_channel::Event::Closed => break,
                phoenix_channel::Event::Connected => {
                    channel.send("test", OutboundMsg::Bar).unwrap();
                    channel.send("test", OutboundMsg::Bar).unwrap();
                    channel.send("test", OutboundMsg::Bar).unwrap();
                    channel.send("test", OutboundMsg::Bar).unwrap();
                }
            }
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
    use phoenix_channel::PublicKeyParam;

    let _guard = logging::test("debug,wire::api=trace");

    let (server, port) = spawn_websocket_server(|text| {
        match text {
            r#"{"topic":"test","event":"phx_join","payload":null,"ref":0}"# => {
                r#"{"event":"phx_reply","ref":0,"topic":"test","payload":{"status":"ok","response":{}}}"#
            }
            // We only handle the message with `ref: 1` and thus guarantee that the first one is not received.
            r#"{"topic":"test","event":"bar","ref":1}"# => {
                r#"{"topic":"test","event":"foo","payload":null}"#
            }
            other => panic!("Unexpected message: {other}"),
        }
    })
    .await;

    let mut channel = make_test_channel("localhost", port);

    let client = async {
        channel.send("test", OutboundMsg::Bar).unwrap_err();
        channel.connect(
            vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
            Duration::ZERO,
            PublicKeyParam([0u8; 32]),
        );

        loop {
            match std::future::poll_fn(|cx| channel.poll(cx)).await.unwrap() {
                phoenix_channel::Event::Message {
                    msg: InboundMsg::Foo,
                    ..
                } => {
                    channel.close().unwrap();
                }
                phoenix_channel::Event::Hiccup { error, .. } => {
                    panic!("Unexpected hiccup: {error:?}")
                }
                phoenix_channel::Event::Closed => break,
                phoenix_channel::Event::Connected => {
                    channel.send("test", OutboundMsg::Bar).unwrap();
                }
            }
        }
    };

    client.await;
    server.wait().await;
}

#[tokio::test]
async fn replies_with_close_frame_upon_close() {
    use phoenix_channel::PublicKeyParam;

    let _guard = logging::test("debug,wire::api=trace");

    let (server, port) = spawn_websocket_server(|text| {
        match text {
            r#"{"topic":"test","event":"phx_join","payload":null,"ref":0}"# => {
                r#"{"event":"phx_reply","ref":0,"topic":"test","payload":{"status":"ok","response":{}}}"#
            }
            other => panic!("Unexpected message: {other}"),
        }
    })
    .await;

    let mut channel = make_test_channel("localhost", port);

    let (mut connected_tx, mut connected_rx) = futures::channel::mpsc::channel(1);

    let client = tokio::spawn(async move {
        channel.connect(
            vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
            Duration::ZERO,
            PublicKeyParam([0u8; 32]),
        );

        loop {
            match std::future::poll_fn(|cx| channel.poll(cx)).await.unwrap() {
                phoenix_channel::Event::Hiccup { error, .. } => break error,
                phoenix_channel::Event::Closed => panic!("Should not close"),
                phoenix_channel::Event::Message { .. } => {}
                phoenix_channel::Event::Connected => connected_tx.send(()).await.unwrap(),
            }
        }
    });

    connected_rx.recv().await.unwrap(); // Wait for successful connection.

    let server_result = server.stop().await;
    let client_result = client.await.unwrap();

    server_result.unwrap(); // Server should shutdown cleanly.

    assert_eq!(
        format!("{client_result:#}"),
        "Connection hiccup: portal sent empty websocket close frame"
    );
}

#[tokio::test]
async fn times_out_after_missed_heartbeats() {
    use phoenix_channel::PublicKeyParam;

    let _guard = logging::test("debug,wire::api=trace");

    let (server, port) = spawn_websocket_server(|text| {
        match text {
            r#"{"topic":"test","event":"phx_join","payload":null,"ref":0}"# => {
                r#"{"event":"phx_reply","ref":0,"topic":"test","payload":{"status":"ok","response":{}}}"#
            }
            // We send a bogus reply (bad `ref`) to ensure the implementation matches those up correctly.
            r#"{"topic":"phoenix","event":"heartbeat","payload":{},"ref":1}"# => {
                r#"{"event":"phx_reply","ref":9999,"topic":"phoenix","payload":{"status":"ok","response":{}}}"#
            }
            r#"{"topic":"phoenix","event":"heartbeat","payload":{},"ref":2}"# => {
                r#"{"event":"phx_reply","ref":9999,"topic":"phoenix","payload":{"status":"ok","response":{}}}"#
            }
            r#"{"topic":"phoenix","event":"heartbeat","payload":{},"ref":3}"# => {
                r#"{"event":"phx_reply","ref":9999,"topic":"phoenix","payload":{"status":"ok","response":{}}}"#
            }
            r#"{"topic":"phoenix","event":"heartbeat","payload":{},"ref":4}"# => {
                r#"{"event":"phx_reply","ref":9999,"topic":"phoenix","payload":{"status":"ok","response":{}}}"#
            }
            other => panic!("Unexpected message: {other}"),
        }
    })
    .await;

    let mut channel = make_test_channel("localhost", port);

    let client = async {
        channel.connect(
            vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
            Duration::ZERO,
            PublicKeyParam([0u8; 32]),
        );

        loop {
            match std::future::poll_fn(|cx| channel.poll(cx)).await.unwrap() {
                phoenix_channel::Event::Message { .. } => {}
                phoenix_channel::Event::Hiccup { error, .. } => break error,
                phoenix_channel::Event::Closed => {
                    panic!("Channel closed")
                }
                phoenix_channel::Event::Connected => {}
            }
        }
    };

    let error = client.await;
    server.abort();

    assert_eq!(
        format!("{error:#}"),
        "Connection hiccup: too many heartbeats were unanswered"
    );
}

#[tokio::test]
async fn sends_heartbeats_regardless_of_messages() {
    use phoenix_channel::PublicKeyParam;

    let _guard = logging::test("debug,wire::api=trace");

    let num_heartbeats = Arc::new(AtomicUsize::default());

    let (server, port) = spawn_websocket_server({
        let num_heartbeats = num_heartbeats.clone();

        move |text| {
            let msg = serde_json::from_str::<'_, serde_json::Value>(text).unwrap();
            let reference = &msg["ref"];
            let topic = msg["topic"].as_str().unwrap();

            match msg["event"].as_str().unwrap() {
                "phx_join" => {
                    format!(r#"{{"event":"phx_reply","ref":{reference},"topic":"{topic}","payload":{{"status":"ok","response":{{}}}}}}"#)
                }
                "heartbeat" => {
                    num_heartbeats.fetch_add(1, std::sync::atomic::Ordering::SeqCst);

                    format!(r#"{{"event":"phx_reply","ref":{reference},"topic":"phoenix","payload":{{"status":"ok","response":{{}}}}}}"#)
                }
                "bar" => {
                    format!(r#"{{"event":"foo","ref":{reference},"topic":"{topic}","payload":null}}"#)
                }
                other => panic!("Unknown event: {other}")
            }
        }
    })
    .await;

    let mut channel = make_test_channel("localhost", port);

    let client = tokio::spawn(async move {
        channel.connect(
            vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
            Duration::ZERO,
            PublicKeyParam([0u8; 32]),
        );

        let mut message_interval = tokio::time::interval(Duration::from_secs(3));

        loop {
            tokio::select! {
                event = std::future::poll_fn(|cx| channel.poll(cx)) => {
                    match event.unwrap() {
                        phoenix_channel::Event::Message { .. } => {}
                        phoenix_channel::Event::Hiccup { error, .. } => panic!("Connection failed: {error}"),
                        phoenix_channel::Event::Closed => {
                            panic!("Channel closed")
                        }
                        phoenix_channel::Event::Connected => {}
                    }
                }
                _ = message_interval.tick() => {
                    let _ = channel.send("test", OutboundMsg::Bar);
                }
            }
        }
    });

    tokio::time::sleep(Duration::from_secs(25)).await;

    assert_eq!(num_heartbeats.load(std::sync::atomic::Ordering::SeqCst), 2);

    client.abort();
    server.abort();
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

#[tokio::test]
async fn http_429_triggers_retry() {
    let port = http_status_server(http::StatusCode::TOO_MANY_REQUESTS).await;

    let mut channel = make_test_channel("127.0.0.1", port);
    channel.connect(
        vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
        Duration::ZERO,
        PublicKeyParam([0u8; 32]),
    );

    let result = tokio::time::timeout(Duration::from_secs(5), async {
        future::poll_fn(|cx| channel.poll(cx)).await
    })
    .await
    .expect("should not timeout");

    // 429 should trigger a Hiccup (retry) not an Error::Client
    assert!(
        matches!(result, Ok(Event::Hiccup { .. })),
        "expected Event::Hiccup for 429, got {result:?}"
    );
}

#[tokio::test]
async fn http_408_triggers_retry() {
    let port = http_status_server(http::StatusCode::REQUEST_TIMEOUT).await;

    let mut channel = make_test_channel("127.0.0.1", port);

    channel.connect(
        vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
        Duration::ZERO,
        PublicKeyParam([0u8; 32]),
    );

    let result = tokio::time::timeout(Duration::from_secs(5), async {
        future::poll_fn(|cx| channel.poll(cx)).await
    })
    .await
    .expect("should not timeout");

    // 408 should trigger a Hiccup (retry) not an Error::Client
    assert!(
        matches!(result, Ok(Event::Hiccup { .. })),
        "expected Event::Hiccup for 408, got {result:?}"
    );
}

#[tokio::test]
async fn http_400_returns_client_error() {
    let port = http_status_server(http::StatusCode::BAD_REQUEST).await;

    let mut channel = make_test_channel("127.0.0.1", port);

    channel.connect(
        vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
        Duration::ZERO,
        PublicKeyParam([0u8; 32]),
    );

    let result = tokio::time::timeout(Duration::from_secs(5), async {
        future::poll_fn(|cx| channel.poll(cx)).await
    })
    .await
    .expect("should not timeout");

    assert!(
        matches!(result, Ok(Event::Hiccup { .. })),
        "expected Event::Hiccup for 400, got {result:?}"
    );
}

#[tokio::test]
async fn http_401_returns_invalid_token() {
    let port = http_status_server(http::StatusCode::UNAUTHORIZED).await;

    let mut channel = make_test_channel("127.0.0.1", port);

    channel.connect(
        vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
        Duration::ZERO,
        PublicKeyParam([0u8; 32]),
    );

    let result = tokio::time::timeout(Duration::from_secs(5), async {
        future::poll_fn(|cx| channel.poll(cx)).await
    })
    .await
    .expect("should not timeout");

    assert!(
        matches!(result, Err(phoenix_channel::Error::InvalidToken)),
        "expected Error::InvalidToken for 401, got {result:?}"
    );
}

#[tokio::test]
async fn includes_ip_from_hostname() {
    use phoenix_channel::PublicKeyParam;

    let _guard = logging::test("debug,wire::api=trace");

    let (server, port) = spawn_websocket_server(|text| {
        match text {
            r#"{"topic":"test","event":"phx_join","payload":null,"ref":0}"# => {
                r#"{"event":"phx_reply","ref":0,"topic":"test","payload":{"status":"ok","response":{}}}"#
            }
            other => panic!("Unexpected message: {other}"),
        }
    })
    .await;

    let mut channel = make_test_channel("127.0.0.1", port);
    channel.connect(vec![], Duration::ZERO, PublicKeyParam([0u8; 32]));

    let client = async {
        loop {
            match std::future::poll_fn(|cx| channel.poll(cx)).await.unwrap() {
                phoenix_channel::Event::Message { .. } => {}
                phoenix_channel::Event::Hiccup { error, .. } => panic!("{error:#}"),
                phoenix_channel::Event::Closed => {
                    panic!("Channel closed")
                }
                phoenix_channel::Event::Connected => break,
            }
        }
    };

    client.await;
    server.abort();
}

/// Spawns a WebSocket server that responds to requests using a handler function.
/// Returns the server task handle and the port number.
async fn spawn_websocket_server<F, R>(handler: F) -> (ServerHandle, u16)
where
    F: Fn(&str) -> R + Send + 'static,
    R: Into<tokio_tungstenite::tungstenite::Utf8Bytes>,
{
    use futures::{SinkExt, StreamExt};
    use tokio::net::TcpListener;
    use tokio_tungstenite::tungstenite::Message;

    let listener = TcpListener::bind("0.0.0.0:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (close_tx, mut close_rx) = futures::channel::mpsc::channel(1);

    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();

        loop {
            match futures::future::select(ws.next(), close_rx.recv()).await {
                futures::future::Either::Left((Some(Ok(Message::Text(text))), _)) => {
                    let response = handler(text.as_str());
                    ws.send(Message::text(response)).await.unwrap();
                }
                futures::future::Either::Left((Some(Ok(Message::Close(_))), _)) => continue,
                futures::future::Either::Left((Some(other), _)) => {
                    panic!("Unexpected message: {other:?}")
                }
                futures::future::Either::Left((None, _)) => break,
                futures::future::Either::Right((Err(_), _)) => continue,
                futures::future::Either::Right((Ok(()), _)) => {
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

fn make_test_channel(
    host: &str,
    port: u16,
) -> PhoenixChannel<(), OutboundMsg, InboundMsg, PublicKeyParam> {
    let url = LoginUrl::client(
        format!("ws://{host}:{port}").as_str(),
        "test-device-id".to_string(),
        Some("test-device".to_string()),
        DeviceInfo::default(),
    )
    .unwrap();

    PhoenixChannel::disconnected(
        url,
        SecretString::from("test_token"),
        "test-user-agent".to_string(),
        "test",
        (),
        || {
            backoff::ExponentialBackoffBuilder::new()
                .with_initial_interval(std::time::Duration::from_secs(1))
                .with_max_elapsed_time(Some(std::time::Duration::from_secs(60)))
                .build()
        },
        Arc::new(socket_factory::tcp),
    )
}

async fn http_status_server(code: http::StatusCode) -> u16 {
    http_response_server(format!(
        "HTTP/1.1 {status} {reason}\r\n\
         Connection: close\r\n\
         Content-Type: text/plain\r\n\
         Content-Length: 0\r\n\r\n",
        status = code.as_u16(),
        reason = code.as_str()
    ))
    .await
}

async fn http_status_server_with_retry_after(status: u16, reason: &str, retry_after: u64) -> u16 {
    http_response_server(format!(
        "HTTP/1.1 {status} {reason}\r\n\
         Connection: close\r\n\
         Content-Type: text/plain\r\n\
         Retry-After: {retry_after}\r\n\
         Content-Length: 0\r\n\r\n"
    ))
    .await
}

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
                        tokio::io::AsyncReadExt::read(&mut socket, &mut buf[total_read..]),
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

#[tokio::test]
async fn http_503_triggers_retry() {
    let port = http_status_server(http::StatusCode::SERVICE_UNAVAILABLE).await;

    let mut channel = make_test_channel("127.0.0.1", port);

    channel.connect(
        vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
        Duration::ZERO,
        PublicKeyParam([0u8; 32]),
    );

    let result = tokio::time::timeout(Duration::from_secs(5), async {
        future::poll_fn(|cx| channel.poll(cx)).await
    })
    .await
    .expect("should not timeout");

    // 503 should trigger a Hiccup (retry) not an Error::Client
    assert!(
        matches!(result, Ok(Event::Hiccup { .. })),
        "expected Event::Hiccup for 503, got {result:?}"
    );
}

#[tokio::test]
async fn http_429_with_retry_after_uses_header_value() {
    let port = http_status_server_with_retry_after(429, "Too Many Requests", 30).await;

    let mut channel = make_test_channel("127.0.0.1", port);

    channel.connect(
        vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
        Duration::ZERO,
        PublicKeyParam([0u8; 32]),
    );

    let result = tokio::time::timeout(Duration::from_secs(5), async {
        future::poll_fn(|cx| channel.poll(cx)).await
    })
    .await
    .expect("should not timeout");

    // 429 with Retry-After should use the header value for backoff
    match result {
        Ok(Event::Hiccup { backoff, .. }) => {
            assert_eq!(backoff, Duration::from_secs(30));
        }
        other => {
            panic!(
                "expected Event::Hiccup with 30s backoff for 429 with Retry-After, got {other:?}"
            )
        }
    }
}

#[tokio::test]
async fn http_503_with_retry_after_uses_header_value() {
    let port = http_status_server_with_retry_after(503, "Service Unavailable", 60).await;

    let mut channel = make_test_channel("127.0.0.1", port);

    channel.connect(
        vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
        Duration::ZERO,
        PublicKeyParam([0u8; 32]),
    );

    let result = tokio::time::timeout(Duration::from_secs(5), async {
        future::poll_fn(|cx| channel.poll(cx)).await
    })
    .await
    .expect("should not timeout");

    // 503 with Retry-After should use the header value for backoff
    match result {
        Ok(Event::Hiccup { backoff, .. }) => {
            assert_eq!(backoff, Duration::from_secs(60));
        }
        other => {
            panic!(
                "expected Event::Hiccup with 60s backoff for 503 with Retry-After, got {other:?}"
            )
        }
    }
}

#[tokio::test]
async fn initial_connection_uses_constant_1s_backoff() {
    use phoenix_channel::{Error, PublicKeyParam};
    use std::time::Duration;

    let _guard = logging::test("debug");

    let mut channel = make_test_channel("127.0.0.1", 1);
    channel.connect(
        vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
        Duration::ZERO,
        PublicKeyParam([0u8; 32]),
    );

    let start = std::time::Instant::now();

    loop {
        match std::future::poll_fn(|cx| channel.poll(cx)).await {
            Ok(phoenix_channel::Event::Hiccup {
                backoff,
                max_elapsed_time,
                ..
            }) => {
                assert_eq!(max_elapsed_time, Some(Duration::from_secs(15)));
                assert_eq!(backoff, Duration::from_secs(1));

                channel.connect(
                    vec![IpAddr::from(Ipv4Addr::LOCALHOST)],
                    backoff,
                    PublicKeyParam([0u8; 32]),
                );
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
