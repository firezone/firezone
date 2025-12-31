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
        &SecretString::from("secret"),
        String::new(),
        None,
        DeviceInfo::default(),
    )
    .unwrap();

    let mut channel = PhoenixChannel::<(), OutboundMsg, InboundMsg, _>::disconnected(
        login_url,
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
        &SecretString::from("secret"),
        String::new(),
        None,
        DeviceInfo::default(),
    )
    .unwrap();

    let mut channel = PhoenixChannel::<(), OutboundMsg, InboundMsg, _>::disconnected(
        login_url,
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

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
enum InboundMsg {
    Foo,
}

#[derive(serde::Serialize, serde::Deserialize, Debug, PartialEq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
enum OutboundMsg {
    Bar,
}
