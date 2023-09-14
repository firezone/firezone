use std::collections::HashSet;
use std::{fmt, marker::PhantomData, time::Duration};

use base64::Engine;
use futures::{FutureExt, SinkExt, StreamExt};
use rand_core::{OsRng, RngCore};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::pin::Pin;
use std::task::{Context, Poll};
use tokio::net::TcpStream;
use tokio::time::Instant;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{handshake::client::Request, Message},
    MaybeTlsStream, WebSocketStream,
};
use url::Url;

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);

pub struct PhoenixChannel<TInboundMsg, TOutboundRes> {
    stream: WebSocketStream<MaybeTlsStream<TcpStream>>,
    pending_messages: Vec<Message>,
    next_request_id: u64,

    next_heartbeat: Pin<Box<tokio::time::Sleep>>,

    _phantom: PhantomData<(TInboundMsg, TOutboundRes)>,

    pending_join_requests: HashSet<OutboundRequestId>,
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("provided URI is missing a host")]
    MissingHost,
    #[error(transparent)]
    WebSocket(#[from] tokio_tungstenite::tungstenite::Error),
    #[error("failed to serialize message")]
    Serde(#[from] serde_json::Error),
    #[error("server sent a reply without a reference")]
    MissingReplyId,
}

#[derive(Debug, PartialEq, Eq, Hash)]
pub struct OutboundRequestId(u64);

impl fmt::Display for OutboundRequestId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "OutReq-{}", self.0)
    }
}

#[derive(Debug, PartialEq, Eq, Hash)]
pub struct InboundRequestId(u64);

impl fmt::Display for InboundRequestId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "InReq-{}", self.0)
    }
}

impl<TInboundMsg, TOutboundRes> PhoenixChannel<TInboundMsg, TOutboundRes>
where
    TInboundMsg: DeserializeOwned,
    TOutboundRes: DeserializeOwned,
{
    /// Creates a new [PhoenixChannel] to the given endpoint.
    ///
    /// The provided URL must contain a host.
    /// Additionally, you must already provide any query parameters required for authentication.
    pub async fn connect(url: Url, user_agent: String) -> Result<Self, Error> {
        tracing::trace!("Trying to connect to the portal...");

        let (stream, _) = connect_async(make_request(&url, user_agent)?).await?;

        tracing::trace!("Successfully connected to portal");

        Ok(Self {
            stream,
            pending_messages: vec![],
            _phantom: PhantomData,
            next_request_id: 0,
            next_heartbeat: Box::pin(tokio::time::sleep(HEARTBEAT_INTERVAL)),
            pending_join_requests: Default::default(),
        })
    }

    /// Join the provided room.
    ///
    /// If successful, a [`Event::JoinedRoom`] event will be emitted.
    pub fn join(&mut self, topic: impl Into<String>, payload: impl Serialize) {
        let request_id = self.send_message(topic, EgressControlMessage::PhxJoin(payload));

        self.pending_join_requests.insert(request_id);
    }

    /// Send a message to a topic.
    pub fn send(&mut self, topic: impl Into<String>, message: impl Serialize) -> OutboundRequestId {
        self.send_message(topic, message)
    }

    pub fn poll(
        &mut self,
        cx: &mut Context,
    ) -> Poll<Result<Event<TInboundMsg, TOutboundRes>, Error>> {
        loop {
            // Priority 1: Keep local buffers small and send pending messages.
            if self.stream.poll_ready_unpin(cx).is_ready() {
                if let Some(message) = self.pending_messages.pop() {
                    self.stream.start_send_unpin(message)?;
                    continue;
                }
            }

            // Priority 2: Handle incoming messages.
            if let Poll::Ready(Some(message)) = self.stream.poll_next_unpin(cx)? {
                let Ok(text) = message.into_text() else {
                    tracing::warn!("Received non-text message from portal");
                    continue;
                };

                tracing::trace!("Received message from portal: {text}");

                let message = match serde_json::from_str::<PhoenixMessage<TInboundMsg, TOutboundRes>>(
                    &text,
                ) {
                    Ok(m) => m,
                    Err(e) => {
                        tracing::warn!("Failed to deserialize message {text}: {e}");
                        continue;
                    }
                };

                match message.payload {
                    Payload::Message(msg) => match message.reference {
                        None => {
                            return Poll::Ready(Ok(Event::InboundMessage {
                                topic: message.topic,
                                msg,
                            }))
                        }
                        Some(reference) => {
                            return Poll::Ready(Ok(Event::InboundReq {
                                req_id: InboundRequestId(reference),
                                req: msg,
                            }))
                        }
                    },
                    Payload::Reply(ReplyMessage::PhxReply(PhxReply::Error(ErrorInfo::Reason(
                        reason,
                    )))) => {
                        return Poll::Ready(Ok(Event::ErrorResponse {
                            topic: message.topic,
                            req_id: OutboundRequestId(
                                message.reference.ok_or(Error::MissingReplyId)?,
                            ),
                            reason,
                        }));
                    }
                    Payload::Reply(ReplyMessage::PhxReply(PhxReply::Ok(OkReply::Message(
                        reply,
                    )))) => {
                        let req_id =
                            OutboundRequestId(message.reference.ok_or(Error::MissingReplyId)?);

                        if self.pending_join_requests.remove(&req_id) {
                            // For `phx_join` requests, `reply` is empty so we can safely ignore it.
                            return Poll::Ready(Ok(Event::JoinedRoom {
                                topic: message.topic,
                            }));
                        }

                        return Poll::Ready(Ok(Event::SuccessResponse {
                            topic: message.topic,
                            req_id,
                            res: reply,
                        }));
                    }
                    Payload::Reply(ReplyMessage::PhxReply(PhxReply::Error(ErrorInfo::Offline))) => {
                        tracing::warn!(
                            "Received offline error for request {:?}",
                            message.reference
                        );
                        continue;
                    }
                    Payload::Reply(ReplyMessage::PhxReply(PhxReply::Ok(OkReply::NoMessage(
                        Empty {},
                    )))) => {
                        tracing::trace!("Received empty reply for request {:?}", message.reference);
                        continue;
                    }
                    Payload::Reply(ReplyMessage::PhxError(Empty {})) => {
                        return Poll::Ready(Ok(Event::ErrorResponse {
                            topic: message.topic,
                            req_id: OutboundRequestId(
                                message.reference.ok_or(Error::MissingReplyId)?,
                            ),
                            reason: "unknown error (bad event?)".to_owned(),
                        }))
                    }
                }
            }

            // Priority 3: Handle heartbeats.
            if self.next_heartbeat.poll_unpin(cx).is_ready() {
                self.send_message("phoenix", EgressControlMessage::<()>::Heartbeat(Empty {}));
                self.next_heartbeat
                    .as_mut()
                    .reset(Instant::now() + HEARTBEAT_INTERVAL);

                return Poll::Ready(Ok(Event::HeartbeatSent));
            }

            return Poll::Pending;
        }
    }

    fn send_message(
        &mut self,
        topic: impl Into<String>,
        payload: impl Serialize,
    ) -> OutboundRequestId {
        let request_id = self.fetch_add_request_id();

        self.pending_messages.push(Message::Text(
            // We don't care about the reply type when serializing
            serde_json::to_string(&PhoenixMessage::<_, ()>::new(topic, payload, request_id))
                .expect("we should always be able to serialize a join topic message"),
        ));

        OutboundRequestId(request_id)
    }

    fn fetch_add_request_id(&mut self) -> u64 {
        let next_id = self.next_request_id;
        self.next_request_id += 1;

        next_id
    }
}

#[derive(Debug)]
pub enum Event<TInboundMsg, TOutboundRes> {
    SuccessResponse {
        topic: String,
        req_id: OutboundRequestId,
        /// The response received for an outbound request.
        res: TOutboundRes,
    },
    JoinedRoom {
        topic: String,
    },
    HeartbeatSent,
    ErrorResponse {
        topic: String,
        req_id: OutboundRequestId,
        reason: String,
    },
    /// The server sent us a message, most likely this is a broadcast to all connected clients.
    InboundMessage {
        topic: String,
        msg: TInboundMsg,
    },
    /// The server sent us a request and is expecting a response.
    InboundReq {
        req_id: InboundRequestId,
        req: TInboundMsg,
    },
}

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize, Clone)]
#[serde(untagged)]
enum Payload<T, R> {
    // We might want other type for the reply message
    // but that makes everything even more convoluted!
    // and we need to think how to make this whole mess less convoluted.
    Reply(ReplyMessage<R>),
    Message(T),
}

#[derive(Debug, PartialEq, Eq, Clone, Deserialize, Serialize)]
pub struct PhoenixMessage<T, R> {
    topic: String,
    #[serde(flatten)]
    payload: Payload<T, R>,
    #[serde(rename = "ref")]
    reference: Option<u64>,
}

impl<T, R> PhoenixMessage<T, R> {
    pub fn new(topic: impl Into<String>, payload: T, reference: u64) -> Self {
        Self {
            topic: topic.into(),
            payload: Payload::Message(payload),
            reference: Some(reference),
        }
    }
}

// This is basically the same as tungstenite does but we add some new headers (namely user-agent)
fn make_request(uri: &Url, user_agent: String) -> Result<Request, Error> {
    let host = uri.host().ok_or(Error::MissingHost)?;
    let host = if let Some(port) = uri.port() {
        format!("{host}:{port}")
    } else {
        host.to_string()
    };

    let mut r = [0u8; 16];
    OsRng.fill_bytes(&mut r);
    let key = base64::engine::general_purpose::STANDARD.encode(r);

    let req = Request::builder()
        .method("GET")
        .header("Host", host)
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header("Sec-WebSocket-Version", "13")
        .header("Sec-WebSocket-Key", key)
        .header("User-Agent", user_agent)
        .uri(uri.as_str())
        .body(())
        .expect("building static request always works");

    Ok(req)
}

// Awful hack to get serde_json to generate an empty "{}" instead of using "null"
#[derive(Debug, Deserialize, Serialize, PartialEq, Eq, Clone)]
#[serde(deny_unknown_fields)]
struct Empty {}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
enum EgressControlMessage<T> {
    PhxJoin(T),
    Heartbeat(Empty),
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
enum ReplyMessage<T> {
    PhxReply(PhxReply<T>),
    PhxError(Empty),
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(untagged)]
enum OkReply<T> {
    Message(T),
    NoMessage(Empty),
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum ErrorInfo {
    Reason(String),
    Offline,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "status", content = "response")]
enum PhxReply<T> {
    Ok(OkReply<T>),
    Error(ErrorInfo),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Deserialize, PartialEq, Debug)]
    #[serde(rename_all = "snake_case", tag = "event", content = "payload")] // This line makes it all work.
    enum Msg {
        Shout { hello: String },
        Init {},
    }

    #[test]
    fn can_deserialize_inbound_message() {
        let msg = r#"{
  "topic": "room:lobby",
  "ref": null,
  "payload": {
    "hello": "world"
  },
  "join_ref": null,
  "event": "shout"
}"#;

        let msg = serde_json::from_str::<PhoenixMessage<Msg, ()>>(msg).unwrap();

        assert_eq!(msg.topic, "room:lobby");
        assert_eq!(msg.reference, None);
        assert_eq!(
            msg.payload,
            Payload::Message(Msg::Shout {
                hello: "world".to_owned()
            })
        );
    }
    #[test]
    fn can_deserialize_init_message() {
        let msg = r#"{"event":"init","payload":{},"ref":null,"topic":"relay"}"#;

        let msg = serde_json::from_str::<PhoenixMessage<Msg, ()>>(msg).unwrap();

        assert_eq!(msg.topic, "relay");
        assert_eq!(msg.reference, None);
        assert_eq!(msg.payload, Payload::Message(Msg::Init {}));
    }
}
