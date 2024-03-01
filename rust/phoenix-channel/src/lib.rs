mod heartbeat;

use std::collections::{HashSet, VecDeque};
use std::{fmt, future, marker::PhantomData};

use backoff::backoff::Backoff;
use backoff::ExponentialBackoff;
use base64::Engine;
use futures::future::BoxFuture;
use futures::{FutureExt, SinkExt, StreamExt};
use heartbeat::{Heartbeat, MissedLastHeartbeat};
use rand_core::{OsRng, RngCore};
use secrecy::{CloneableSecret, ExposeSecret as _, Secret};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::task::{ready, Context, Poll};
use tokio::net::TcpStream;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{handshake::client::Request, Message},
    MaybeTlsStream, WebSocketStream,
};
use url::Url;

// TODO: Refactor this PhoenixChannel to be compatible with the needs of the client and gateway
// See https://github.com/firezone/firezone/issues/2158
pub struct PhoenixChannel<TInitReq, TInboundMsg, TOutboundRes> {
    state: State,
    pending_messages: VecDeque<String>,
    next_request_id: u64,

    heartbeat: Heartbeat,

    _phantom: PhantomData<(TInboundMsg, TOutboundRes)>,

    pending_join_requests: HashSet<OutboundRequestId>,

    // Stored here to allow re-connecting.
    secret_url: Secret<SecureUrl>,
    user_agent: String,
    reconnect_backoff: ExponentialBackoff,

    login: &'static str,
    init_req: TInitReq,
}

enum State {
    Connected(WebSocketStream<MaybeTlsStream<TcpStream>>),
    Connecting(BoxFuture<'static, Result<WebSocketStream<MaybeTlsStream<TcpStream>>, Error>>),
}

/// Creates a new [PhoenixChannel] to the given endpoint and waits for an `init` message.
///
/// The provided URL must contain a host.
/// Additionally, you must already provide any query parameters required for authentication.
#[tracing::instrument(level = "debug", skip(payload, secret_url, reconnect_backoff))]
#[allow(clippy::type_complexity)]
pub async fn init<TInitReq, TInitRes, TInboundMsg, TOutboundRes>(
    secret_url: Secret<SecureUrl>,
    user_agent: String,
    login_topic: &'static str,
    payload: TInitReq,
    reconnect_backoff: ExponentialBackoff,
) -> Result<
    Result<
        (
            PhoenixChannel<TInitReq, TInboundMsg, TOutboundRes>,
            TInitRes,
        ),
        UnexpectedEventDuringInit,
    >,
    Error,
>
where
    TInitReq: Serialize + Clone,
    TInitRes: DeserializeOwned + fmt::Debug,
    TInboundMsg: DeserializeOwned,
    TOutboundRes: DeserializeOwned,
{
    let mut channel = PhoenixChannel::<_, InitMessage<TInitRes>, ()>::connect(
        secret_url,
        user_agent,
        login_topic,
        payload,
        reconnect_backoff,
    );

    tracing::info!("Connected to portal, waiting for `init` message");

    let (channel, init_message) = loop {
        match future::poll_fn(|cx| channel.poll(cx)).await? {
            Event::InboundMessage {
                topic,
                msg: InitMessage::Init(msg),
            } if topic == login_topic => {
                tracing::info!("Received init message from portal");

                break (channel, msg);
            }
            Event::HeartbeatSent => {}
            e => return Ok(Err(UnexpectedEventDuringInit(format!("{e:?}")))),
        }
    };

    Ok(Ok((channel.cast(), init_message)))
}

#[derive(serde::Deserialize, Debug, PartialEq)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
pub enum InitMessage<M> {
    Init(M),
}

#[derive(Debug, thiserror::Error)]
#[error("encountered unexpected event during init: {0}")]
pub struct UnexpectedEventDuringInit(String);

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("provided URI is missing a host")]
    MissingHost,
    #[error("websocket failed")]
    WebSocket(#[from] tokio_tungstenite::tungstenite::Error),
    #[error("failed to serialize message")]
    Serde(#[from] serde_json::Error),
    #[error("server sent a reply without a reference")]
    MissingReplyId,
    #[error("server did not reply to our heartbeat")]
    MissedHeartbeat,
    #[error("connection close message")]
    CloseMessage,
}

#[derive(Debug, PartialEq, Eq, Hash)]
pub struct OutboundRequestId(u64);

impl OutboundRequestId {
    #[cfg(test)]
    pub(crate) fn new(id: u64) -> Self {
        Self(id)
    }
}

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

#[derive(Clone)]
pub struct SecureUrl {
    inner: Url,
}

impl SecureUrl {
    pub fn from_url(url: Url) -> Self {
        Self { inner: url }
    }

    /// Exposes the `host` of the URL.
    ///
    /// The host doesn't contain any secrets.
    pub fn host(&self) -> Option<&str> {
        self.inner.host_str()
    }
}

impl CloneableSecret for SecureUrl {}

impl secrecy::Zeroize for SecureUrl {
    fn zeroize(&mut self) {
        let placeholder = Url::parse("http://a.com").expect("placeholder URL to be valid");
        let _ = std::mem::replace(&mut self.inner, placeholder);
    }
}

impl<TInitReq, TInboundMsg, TOutboundRes> PhoenixChannel<TInitReq, TInboundMsg, TOutboundRes>
where
    TInitReq: Serialize + Clone,
    TInboundMsg: DeserializeOwned,
    TOutboundRes: DeserializeOwned,
{
    /// Creates a new [PhoenixChannel] to the given endpoint.
    ///
    /// The provided URL must contain a host.
    /// Additionally, you must already provide any query parameters required for authentication.
    ///
    /// Once the connection is established,
    pub fn connect(
        secret_url: Secret<SecureUrl>,
        user_agent: String,
        login: &'static str,
        init_req: TInitReq,
        reconnect_backoff: ExponentialBackoff,
    ) -> Self {
        Self {
            reconnect_backoff,
            secret_url: secret_url.clone(),
            user_agent: user_agent.clone(),
            state: State::Connecting(Box::pin(async move {
                let (stream, _) = connect_async(make_request(secret_url, user_agent)?).await?;

                Ok(stream)
            })),
            pending_messages: Default::default(),
            _phantom: PhantomData,
            next_request_id: 0,
            heartbeat: Default::default(),
            pending_join_requests: Default::default(),
            login,
            init_req: init_req.clone(),
        }
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
            // First, check if we are connected.
            let stream = match &mut self.state {
                State::Connected(stream) => stream,
                State::Connecting(future) => match ready!(future.poll_unpin(cx)) {
                    Ok(stream) => {
                        self.reconnect_backoff.reset();
                        self.state = State::Connected(stream);

                        let host = self
                            .secret_url
                            .expose_secret()
                            .host()
                            .expect("always has host");

                        tracing::info!(%host, "Connected to portal");
                        self.join(self.login, self.init_req.clone());

                        continue;
                    }
                    Err(e) => {
                        if let Error::WebSocket(tokio_tungstenite::tungstenite::Error::Http(r)) = &e
                        {
                            let status = r.status();

                            if status.is_client_error() {
                                let body = r
                                    .body()
                                    .as_deref()
                                    .map(String::from_utf8_lossy)
                                    .unwrap_or_default();

                                tracing::warn!(
                                    "Fatal client error ({status}) in portal connection: {body}"
                                );

                                return Poll::Ready(Err(e));
                            }
                        };

                        let Some(backoff) = self.reconnect_backoff.next_backoff() else {
                            tracing::warn!("Reconnect backoff expired");
                            return Poll::Ready(Err(e));
                        };

                        let secret_url = self.secret_url.clone();
                        let user_agent = self.user_agent.clone();

                        tracing::debug!(?backoff, max_elapsed_time = ?self.reconnect_backoff.max_elapsed_time, "Reconnecting to portal on transient client error: {:#}", anyhow::Error::from(e));

                        self.state = State::Connecting(Box::pin(async move {
                            tokio::time::sleep(backoff).await;

                            let (stream, _) =
                                connect_async(make_request(secret_url, user_agent)?).await?;

                            Ok(stream)
                        }));
                        continue;
                    }
                },
            };

            // Priority 1: Keep local buffers small and send pending messages.
            if stream.poll_ready_unpin(cx).is_ready() {
                if let Some(message) = self.pending_messages.pop_front() {
                    tracing::trace!(target: "wire", to="portal", %message);

                    match stream.start_send_unpin(Message::Text(message)) {
                        Ok(()) => {}
                        Err(e) => {
                            self.reconnect_on_transient_error(Error::WebSocket(e));
                        }
                    }
                    continue;
                }
            }

            // Priority 2: Handle incoming messages.
            match stream.poll_next_unpin(cx) {
                Poll::Ready(Some(Ok(message))) => {
                    let Ok(message) = message.into_text() else {
                        tracing::warn!("Received non-text message from portal");
                        continue;
                    };

                    tracing::trace!(target: "wire", from="portal", %message);

                    let message = match serde_json::from_str::<
                        PhoenixMessage<TInboundMsg, TOutboundRes>,
                    >(&message)
                    {
                        Ok(m) => m,
                        Err(e) if e.is_io() || e.is_eof() => {
                            self.reconnect_on_transient_error(Error::Serde(e));
                            continue;
                        }
                        Err(e) => {
                            tracing::warn!("Failed to deserialize message {message}: {e}");
                            continue;
                        }
                    };

                    match message.payload {
                        Payload::Message(msg) => {
                            return Poll::Ready(Ok(Event::InboundMessage {
                                topic: message.topic,
                                msg,
                            }))
                        }
                        Payload::Reply(Reply::Error { reason }) => {
                            return Poll::Ready(Ok(Event::ErrorResponse {
                                topic: message.topic,
                                req_id: OutboundRequestId(
                                    message.reference.ok_or(Error::MissingReplyId)?,
                                ),
                                reason,
                            }));
                        }
                        Payload::Reply(Reply::Ok(OkReply::Message(reply))) => {
                            let req_id =
                                OutboundRequestId(message.reference.ok_or(Error::MissingReplyId)?);

                            if self.pending_join_requests.remove(&req_id) {
                                tracing::info!("Joined {} room on portal", message.topic);

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
                        Payload::Reply(Reply::Ok(OkReply::NoMessage(Empty {}))) => {
                            let id =
                                OutboundRequestId(message.reference.ok_or(Error::MissingReplyId)?);

                            if self.heartbeat.maybe_handle_reply(id) {
                                continue;
                            }

                            tracing::trace!(
                                "Received empty reply for request {:?}",
                                message.reference
                            );

                            continue;
                        }
                        Payload::Error(Empty {}) => {
                            return Poll::Ready(Ok(Event::ErrorResponse {
                                topic: message.topic,
                                req_id: OutboundRequestId(
                                    message.reference.ok_or(Error::MissingReplyId)?,
                                ),
                                reason: ErrorReply::Other,
                            }))
                        }
                        Payload::Close(Empty {}) => {
                            self.reconnect_on_transient_error(Error::CloseMessage);
                            continue;
                        }
                        Payload::Disconnect { reason } => {
                            return Poll::Ready(Ok(Event::Disconnect(reason)));
                        }
                    }
                }
                Poll::Ready(Some(Err(e))) => {
                    self.reconnect_on_transient_error(Error::WebSocket(e));
                    continue;
                }
                _ => (),
            }

            // Priority 3: Handle heartbeats.
            match self.heartbeat.poll(cx) {
                Poll::Ready(Ok(msg)) => {
                    let id = self.send_message("phoenix", msg);
                    self.heartbeat.set_id(id);

                    return Poll::Ready(Ok(Event::HeartbeatSent));
                }
                Poll::Ready(Err(MissedLastHeartbeat {})) => {
                    self.reconnect_on_transient_error(Error::MissedHeartbeat);
                    continue;
                }
                _ => (),
            }

            // Priority 4: Flush out.
            match stream.poll_flush_unpin(cx) {
                Poll::Ready(Ok(())) => {
                    tracing::trace!("Flushed websocket");
                }
                Poll::Ready(Err(e)) => {
                    self.reconnect_on_transient_error(Error::WebSocket(e));
                    continue;
                }
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }

    /// Sets the channels state to [`State::Connecting`] with the given error.
    ///
    /// The [`PhoenixChannel::poll`] function will handle the reconnect if appropriate for the given error.
    fn reconnect_on_transient_error(&mut self, e: Error) {
        self.state = State::Connecting(future::ready(Err(e)).boxed())
    }

    fn send_message(
        &mut self,
        topic: impl Into<String>,
        payload: impl Serialize,
    ) -> OutboundRequestId {
        let request_id = self.fetch_add_request_id();

        // We don't care about the reply type when serializing
        let msg = serde_json::to_string(&PhoenixMessage::<_, ()>::new(topic, payload, request_id))
            .expect("we should always be able to serialize a join topic message");

        self.pending_messages.push_back(msg);

        OutboundRequestId(request_id)
    }

    fn fetch_add_request_id(&mut self) -> u64 {
        let next_id = self.next_request_id;
        self.next_request_id += 1;

        next_id
    }

    /// Cast this instance of [PhoenixChannel] to new message types.
    fn cast<TInboundMsgNew, TOutboundResNew>(
        self,
    ) -> PhoenixChannel<TInitReq, TInboundMsgNew, TOutboundResNew> {
        PhoenixChannel {
            state: self.state,
            pending_messages: self.pending_messages,
            next_request_id: self.next_request_id,
            heartbeat: self.heartbeat,
            _phantom: PhantomData,
            pending_join_requests: self.pending_join_requests,
            secret_url: self.secret_url,
            user_agent: self.user_agent,
            reconnect_backoff: self.reconnect_backoff,
            login: self.login,
            init_req: self.init_req,
        }
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
        reason: ErrorReply,
    },
    /// The server sent us a message, most likely this is a broadcast to all connected clients.
    InboundMessage {
        topic: String,
        msg: TInboundMsg,
    },
    Disconnect(String),
}

#[derive(Debug, PartialEq, Eq, Clone, Deserialize, Serialize)]
pub struct PhoenixMessage<T, R> {
    // TODO: we should use a newtype pattern for topics
    topic: String,
    #[serde(flatten)]
    payload: Payload<T, R>,
    #[serde(rename = "ref")]
    reference: Option<u64>,
}

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize, Clone)]
#[serde(tag = "event", content = "payload")]
enum Payload<T, R> {
    #[serde(rename = "phx_reply")]
    Reply(Reply<R>),
    #[serde(rename = "phx_error")]
    Error(Empty),
    #[serde(rename = "phx_close")]
    Close(Empty),
    #[serde(rename = "disconnect")]
    Disconnect { reason: String },
    #[serde(untagged)]
    Message(T),
}

// Awful hack to get serde_json to generate an empty "{}" instead of using "null"
#[derive(Debug, Deserialize, Serialize, PartialEq, Eq, Clone)]
#[serde(deny_unknown_fields)]
struct Empty {}

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize, Clone)]
#[serde(rename_all = "snake_case", tag = "status", content = "response")]
enum Reply<T> {
    Ok(OkReply<T>),
    Error { reason: ErrorReply },
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(untagged)]
enum OkReply<T> {
    Message(T),
    NoMessage(Empty),
}

/// This represents the info we have about the error
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorReply {
    #[serde(rename = "unmatched topic")]
    UnmatchedTopic,
    TokenExpired,
    NotFound,
    Offline,
    Disabled,
    #[serde(other)]
    Other,
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
fn make_request(secret_url: Secret<SecureUrl>, user_agent: String) -> Result<Request, Error> {
    use secrecy::ExposeSecret;

    let host = secret_url
        .expose_secret()
        .inner
        .host()
        .ok_or(Error::MissingHost)?;
    let host = if let Some(port) = secret_url.expose_secret().inner.port() {
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
        .uri(secret_url.expose_secret().inner.as_str())
        .body(())
        .expect("building static request always works");

    Ok(req)
}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
enum EgressControlMessage<T> {
    PhxJoin(T),
    Heartbeat(Empty),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Deserialize, PartialEq, Debug)]
    #[serde(rename_all = "snake_case", tag = "event", content = "payload")] // This line makes it all work.
    enum Msg {
        Shout { hello: String },
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
        #[derive(Deserialize, PartialEq, Debug)]
        struct EmptyInit {}

        let msg = r#"{"event":"init","payload":{},"ref":null,"topic":"relay"}"#;

        let msg = serde_json::from_str::<PhoenixMessage<InitMessage<EmptyInit>, ()>>(msg).unwrap();

        assert_eq!(msg.topic, "relay");
        assert_eq!(msg.reference, None);
        assert_eq!(
            msg.payload,
            Payload::Message(InitMessage::Init(EmptyInit {}))
        );
    }

    #[test]
    fn unmatched_topic_reply() {
        let actual_reply = r#"
            {
               "event": "phx_reply",
               "ref": "12",
               "topic": "client",
               "payload":{
                  "status": "error",
                  "response":{
                     "reason": "unmatched topic"
                  }
               }
            }
        "#;
        let actual_reply: Payload<(), ()> = serde_json::from_str(actual_reply).unwrap();
        let expected_reply = Payload::<(), ()>::Reply(Reply::Error {
            reason: ErrorReply::UnmatchedTopic,
        });
        assert_eq!(actual_reply, expected_reply);
    }

    #[test]
    fn phx_close() {
        let actual_reply = r#"
        {
          "event": "phx_close",
          "ref": null,
          "topic": "client",
          "payload": {}
        }
        "#;
        let actual_reply: Payload<(), ()> = serde_json::from_str(actual_reply).unwrap();
        let expected_reply = Payload::<(), ()>::Close(Empty {});
        assert_eq!(actual_reply, expected_reply);
    }

    #[test]
    fn token_expired() {
        let actual_reply = r#"
        {
          "event": "disconnect",
          "ref": null,
          "topic": "client",
          "payload": { "reason": "token_expired" }
        }
        "#;
        let actual_reply: Payload<(), ()> = serde_json::from_str(actual_reply).unwrap();
        let expected_reply = Payload::<(), ()>::Disconnect {
            reason: "token_expired".to_string(),
        };
        assert_eq!(actual_reply, expected_reply);
    }

    #[test]
    fn not_found() {
        let actual_reply = r#"
        {
            "event": "phx_reply",
            "ref": null,
            "topic": "client",
            "payload": {
                "status": "error",
                "response": {
                    "reason": "not_found"
                }
            }
        }
        "#;
        let actual_reply: Payload<(), ()> = serde_json::from_str(actual_reply).unwrap();
        let expected_reply = Payload::<(), ()>::Reply(Reply::Error {
            reason: ErrorReply::NotFound,
        });
        assert_eq!(actual_reply, expected_reply);
    }

    #[test]
    fn unexpected_error_reply() {
        let actual_reply = r#"
            {
               "event": "phx_reply",
               "ref": "12",
               "topic": "client",
               "payload": {
                  "status": "error",
                  "response": {
                     "reason": "bad reply"
                  }
               }
            }
        "#;
        let actual_reply: Payload<(), ()> = serde_json::from_str(actual_reply).unwrap();
        let expected_reply = Payload::<(), ()>::Reply(Reply::Error {
            reason: ErrorReply::Other,
        });
        assert_eq!(actual_reply, expected_reply);
    }
}
