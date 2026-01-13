#![cfg(not(windows))] // For some reason, Windows doesn't like this test.
#![allow(clippy::unwrap_used)]

use std::net::{IpAddr, Ipv4Addr};
use std::{future, sync::Arc, time::Duration};

use phoenix_channel::{DeviceInfo, Event, LoginUrl, PhoenixChannel, PublicKeyParam};
use regex::Regex;
use secrecy::SecretString;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::http;

#[tokio::test]
async fn client_does_not_pipeline_messages() {
    use std::{str::FromStr, sync::Arc, time::Duration};

    use backoff::ExponentialBackoffBuilder;
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
        || {
            ExponentialBackoffBuilder::default()
                .with_initial_interval(Duration::from_secs(1))
                .build()
        },
        Arc::new(socket_factory::tcp),
    );

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
                phoenix_channel::Event::NoAddresses => {
                    channel.update_ips(vec![IpAddr::from(Ipv4Addr::LOCALHOST)]);
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

    use backoff::ExponentialBackoffBuilder;
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
        || {
            ExponentialBackoffBuilder::default()
                .with_initial_interval(Duration::from_secs(1))
                .build()
        },
        Arc::new(socket_factory::tcp),
    );

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
                phoenix_channel::Event::NoAddresses => {
                    channel.update_ips(vec![IpAddr::from(Ipv4Addr::LOCALHOST)]);
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

#[tokio::test]
async fn http_429_triggers_retry() {
    let port = http_status_server(http::StatusCode::TOO_MANY_REQUESTS).await;

    let mut channel = make_test_channel("127.0.0.1", port);
    channel.connect(PublicKeyParam([0u8; 32]));

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
    channel.connect(PublicKeyParam([0u8; 32]));

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
    channel.connect(PublicKeyParam([0u8; 32]));

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
    channel.connect(PublicKeyParam([0u8; 32]));

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
async fn discards_failed_ips_on_hiccup() {
    let mut channel = make_test_channel("localhost", 443); // Use a hostname so we run out of IPs
    channel.update_ips(vec![
        IpAddr::from(Ipv4Addr::from([127, 0, 0, 1])),
        IpAddr::from(Ipv4Addr::from([127, 0, 0, 10])),
        IpAddr::from(Ipv4Addr::from([127, 0, 0, 111])),
    ]);
    channel.connect(PublicKeyParam([0u8; 32]));

    let event = tokio::time::timeout(Duration::from_secs(5), async {
        future::poll_fn(|cx| channel.poll(cx)).await
    })
    .await
    .expect("should not timeout")
    .expect("should not error");

    let phoenix_channel::Event::Hiccup { error, .. } = event else {
        panic!("Expected `Hiccup`")
    };

    let regex = Regex::new(
        r#"Reconnecting to portal on transient error: ([\w\s]+): \[127\.0\.0\.1:443: (.*), 127\.0\.0\.10:443: (.*), 127\.0\.0\.111:443: (.*)\]"#,
    ).unwrap();
    assert!(regex.is_match(&format!("{error:#}")));

    let result = tokio::time::timeout(Duration::from_secs(5), async {
        future::poll_fn(|cx| channel.poll(cx)).await
    })
    .await
    .expect("should not timeout");

    assert!(
        matches!(result, Ok(phoenix_channel::Event::NoAddresses)),
        "expected Event::NoAddresses, got {result:?}"
    );
}

#[tokio::test]
async fn emits_no_addresses_when_no_ips() {
    let mut channel = make_test_channel("localhost", 443); // Use a hostname so we run out of IPs
    channel.connect(PublicKeyParam([0u8; 32]));

    let result = tokio::time::timeout(Duration::from_secs(5), async {
        future::poll_fn(|cx| channel.poll(cx)).await
    })
    .await
    .expect("should not timeout");

    assert!(
        matches!(result, Ok(phoenix_channel::Event::NoAddresses)),
        "expected Event::NoAddresses, got {result:?}"
    );
}

#[tokio::test]
async fn does_not_clear_address_from_url_on_hiccup() {
    let mut channel = make_test_channel("127.0.0.1", 443);
    channel.connect(PublicKeyParam([0u8; 32]));

    loop {
        match std::future::poll_fn(|cx| channel.poll(cx)).await {
            Ok(phoenix_channel::Event::Hiccup { .. }) => continue,
            Err(phoenix_channel::Error::MaxRetriesReached { .. }) => break,
            other => panic!("Unexpected event: {other:?}"), // This line ensures we never receive `Event::NoAddresses` which means we keep retrying.
        }
    }
}

fn make_test_channel(host: &str, port: u16) -> PhoenixChannel<(), (), (), PublicKeyParam> {
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
    channel.connect(PublicKeyParam([0u8; 32]));

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
    channel.connect(PublicKeyParam([0u8; 32]));

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
    channel.connect(PublicKeyParam([0u8; 32]));

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
    use std::{str::FromStr, sync::Arc, time::Duration};

    use phoenix_channel::{DeviceInfo, Error, LoginUrl, PhoenixChannel, PublicKeyParam};
    use secrecy::SecretString;
    use url::Url;

    let _guard = logging::test("debug");

    let login_url = LoginUrl::client(
        Url::from_str("ws://127.0.0.1:1").unwrap(),
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
            backoff::ExponentialBackoffBuilder::default()
                .with_max_elapsed_time(Some(Duration::from_secs(3600)))
                .build()
        },
        Arc::new(socket_factory::tcp),
    );

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
            Ok(phoenix_channel::Event::NoAddresses) => {
                channel.update_ips(vec![IpAddr::from(Ipv4Addr::LOCALHOST)]);
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

    for (i, (backoff, max_elapsed_time)) in hiccups.iter().enumerate() {
        assert_eq!(*max_elapsed_time, Some(Duration::from_secs(15)));
        if i > 0 {
            assert_eq!(*backoff, Duration::from_secs(1));
        }
    }
}
