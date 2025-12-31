#![cfg_attr(test, allow(clippy::unwrap_used))]

mod get_user_agent;
mod login_url;

use anyhow::{Context as _, Result};
use futures::stream::FuturesUnordered;
use std::collections::{BTreeMap, VecDeque};
use std::net::{IpAddr, SocketAddr, ToSocketAddrs as _};
use std::sync::Arc;
use std::time::{Duration, Instant};
use std::{fmt, future, marker::PhantomData};
use std::{io, mem};

use backoff::ExponentialBackoff;
use backoff::backoff::Backoff;
use base64::Engine;
use futures::future::BoxFuture;
use futures::{FutureExt, SinkExt, StreamExt};
use itertools::Itertools as _;
use logging::err_with_src;
use rand_core::{OsRng, RngCore};
use secrecy::{ExposeSecret as _, SecretString};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use socket_factory::{SocketFactory, TcpSocket, TcpStream};
use std::task::{Context, Poll, Waker};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream,
    tungstenite::{Message, handshake::client::Request},
};
use tokio_tungstenite::{client_async_tls, tungstenite};
use url::Url;

pub use get_user_agent::get_user_agent;
pub use login_url::{DeviceInfo, LoginUrl, LoginUrlError, NoParams, PublicKeyParam};
pub use tokio_tungstenite::tungstenite::http::StatusCode;

const MAX_BUFFERED_MESSAGES: usize = 32; // Chosen pretty arbitrarily. If we are connected, these should never build up.

pub struct PhoenixChannel<TInitReq, TOutboundMsg, TInboundMsg, TFinish> {
    state: State,
    waker: Option<Waker>,
    pending_joins: VecDeque<String>,
    pending_messages: VecDeque<PhoenixMessage<TOutboundMsg>>,
    pending_heartbeat: Option<String>,
    next_request_id: u64,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,

    heartbeat: tokio::time::Interval,

    _phantom: PhantomData<TInboundMsg>,

    pending_join_requests: BTreeMap<OutboundRequestId, Instant>,

    // Stored here to allow re-connecting.
    url_prototype: LoginUrl<TFinish>,
    last_url: Option<Url>,
    user_agent: String,
    /// The authentication token, sent via X-Authorization header.
    token: SecretString,
    make_reconnect_backoff: Box<dyn Fn() -> ExponentialBackoff + Send>,
    reconnect_backoff: Option<ExponentialBackoff>,

    resolved_addresses: Vec<IpAddr>,

    login: &'static str,
    init_req: TInitReq,
}

enum State {
    Reconnect {
        backoff: Duration,
    },
    Connected(WebSocketStream<MaybeTlsStream<TcpStream>>),
    Connecting(
        BoxFuture<'static, Result<WebSocketStream<MaybeTlsStream<TcpStream>>, InternalError>>,
    ),
    Closing(WebSocketStream<MaybeTlsStream<TcpStream>>),
    Closed,
}

impl State {
    fn connect(
        url: Url,
        addresses: Vec<SocketAddr>,
        host: String,
        user_agent: String,
        token: SecretString,
        socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    ) -> Self {
        Self::Connecting(
            create_and_connect_websocket(url, addresses, host, user_agent, token, socket_factory)
                .boxed(),
        )
    }
}

async fn create_and_connect_websocket(
    url: Url,
    addresses: Vec<SocketAddr>,
    host: String,
    user_agent: String,
    token: SecretString,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<WebSocketStream<MaybeTlsStream<TcpStream>>, InternalError> {
    tracing::debug!(%host, ?addresses, %user_agent, "Connecting to portal");

    let duration = Duration::from_secs(5);
    let socket = tokio::time::timeout(duration, connect(addresses, &*socket_factory))
        .await
        .map_err(|_| InternalError::Timeout { duration })??;

    let (stream, _) = client_async_tls(make_request(url, host, user_agent, &token), socket)
        .await
        .map_err(InternalError::WebSocket)?;

    Ok(stream)
}

async fn connect(
    addresses: Vec<SocketAddr>,
    socket_factory: &dyn SocketFactory<TcpSocket>,
) -> Result<TcpStream, InternalError> {
    use futures::future::TryFutureExt;

    let mut sockets = addresses
        .into_iter()
        .map(|addr| {
            async move { socket_factory.bind(addr)?.connect(addr).await }
                .map_err(move |e| (addr, e))
        })
        .collect::<FuturesUnordered<_>>();

    let mut errors = Vec::new();

    while let Some(result) = sockets.next().await {
        match result {
            Ok(stream) => return Ok(stream),
            Err(e) => errors.push(e),
        }
    }

    // All attempts failed
    Err(InternalError::SocketConnection(errors))
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Failed to establish WebSocket connection: {0}")]
    Client(StatusCode),
    #[error("Authentication token expired")]
    TokenExpired,
    #[error(
        "Got disconnected from portal and hit the max-retry limit. Last connection error: {final_error}"
    )]
    MaxRetriesReached { final_error: String },
    #[error("Failed to login with portal: {0}")]
    LoginFailed(ErrorReply),
    #[error("Fatal IO error: {0}")]
    FatalIo(io::Error),
}

impl Error {
    pub fn is_authentication_error(&self) -> bool {
        match self {
            Error::Client(s) => s == &StatusCode::UNAUTHORIZED || s == &StatusCode::FORBIDDEN,
            Error::TokenExpired => true,
            Error::MaxRetriesReached { .. } => false,
            Error::LoginFailed(_) => false,
            Error::FatalIo(_) => false,
        }
    }
}

#[derive(Debug)]
enum InternalError {
    WebSocket(tungstenite::Error),
    Serde(serde_json::Error),
    CloseMessage,
    StreamClosed,
    RoomJoinTimedOut,
    SocketConnection(Vec<(SocketAddr, std::io::Error)>),
    Timeout { duration: Duration },
}

impl fmt::Display for InternalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            InternalError::WebSocket(tungstenite::Error::Http(http)) => {
                let status = http.status();
                let body = http
                    .body()
                    .as_deref()
                    .map(String::from_utf8_lossy)
                    .unwrap_or_default();

                write!(f, "http error: {status} - {body}")
            }
            InternalError::WebSocket(_) => write!(f, "websocket connection failed"),
            InternalError::Serde(_) => write!(f, "failed to deserialize message"),
            InternalError::CloseMessage => write!(f, "portal closed the websocket connection"),
            InternalError::StreamClosed => write!(f, "websocket stream was closed"),
            InternalError::SocketConnection(errors) => {
                write!(
                    f,
                    "failed to connect socket: [{}]",
                    errors
                        .iter()
                        .map(|(addr, e)| format!("{addr}: {e}"))
                        .join(", ")
                )
            }
            InternalError::Timeout { duration, .. } => {
                write!(f, "operation timed out after {duration:?}")
            }
            InternalError::RoomJoinTimedOut => write!(f, "room join timed out"),
        }
    }
}

impl std::error::Error for InternalError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            InternalError::WebSocket(tungstenite::Error::Http(_)) => None,
            InternalError::WebSocket(e) => Some(e),
            InternalError::Serde(e) => Some(e),
            InternalError::SocketConnection(_) => None,
            InternalError::CloseMessage => None,
            InternalError::StreamClosed => None,
            InternalError::Timeout { .. } => None,
            InternalError::RoomJoinTimedOut => None,
        }
    }
}

/// Parses a Retry-After header value into a Duration.
///
/// The header can be either:
/// - A number of seconds (e.g., "120")
/// - An HTTP date in IMF-fixdate format (e.g., "Wed, 21 Oct 2015 07:28:00 GMT")
fn parse_retry_after(response: &tungstenite::http::Response<Option<Vec<u8>>>) -> Option<Duration> {
    let header = response.headers().get("retry-after")?;
    let value = header.to_str().ok()?;
    parse_retry_after_value(value)
}

fn parse_retry_after_value(value: &str) -> Option<Duration> {
    // Try parsing as seconds first (most common for 429 responses)
    if let Ok(seconds) = value.parse::<u64>() {
        return Some(Duration::from_secs(seconds));
    }

    // Try parsing as HTTP date (IMF-fixdate format: "Wed, 21 Oct 2015 07:28:00 GMT")
    if let Ok(date) = chrono::DateTime::parse_from_rfc2822(value) {
        let now = chrono::Utc::now();
        let retry_at = date.with_timezone(&chrono::Utc);

        if retry_at > now {
            let duration = retry_at - now;
            return duration.to_std().ok();
        } else {
            // Date is in the past, retry immediately
            return Some(Duration::ZERO);
        }
    }

    None
}

/// A strict-monotonically increasing ID for outbound requests.
#[derive(Debug, PartialEq, Eq, Hash, Deserialize, Serialize, PartialOrd, Ord)]
pub struct OutboundRequestId(u64);

impl OutboundRequestId {
    // Should only be used for unit-testing.
    pub fn for_test(id: u64) -> Self {
        Self(id)
    }

    /// Internal function to make a copy.
    ///
    /// Not exposed publicly because these IDs are meant to be unique.
    pub(crate) fn copy(&self) -> Self {
        Self(self.0)
    }
}

impl fmt::Display for OutboundRequestId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "OutReq-{}", self.0)
    }
}

#[derive(Debug, thiserror::Error)]
#[error("Cannot close websocket while we are connecting")]
pub struct Connecting;

impl<TInitReq, TOutboundMsg, TInboundMsg, TFinish>
    PhoenixChannel<TInitReq, TOutboundMsg, TInboundMsg, TFinish>
where
    TInitReq: Serialize + Clone,
    TOutboundMsg: Serialize + PartialEq + fmt::Debug,
    TInboundMsg: DeserializeOwned,
    TFinish: IntoIterator<Item = (&'static str, String)>,
{
    /// Creates a new [PhoenixChannel] to the given endpoint in the `disconnected` state.
    ///
    /// You must explicitly call [`PhoenixChannel::connect`] to establish a connection.
    ///
    /// The provided URL must contain a host.
    pub fn disconnected(
        url: LoginUrl<TFinish>,
        token: SecretString,
        user_agent: String,
        login: &'static str,
        init_req: TInitReq,
        make_reconnect_backoff: impl Fn() -> ExponentialBackoff + Send + 'static,
        socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    ) -> Result<Self> {
        let host_and_port = url.host_and_port();

        // Statically resolve the host in the URL to a set of addresses.
        // We use these when connecting the socket to avoid a dependency on DNS resolution later on.
        let resolved_addresses = host_and_port
            .to_socket_addrs()
            .with_context(|| format!("Failed to resolve '{}'", host_and_port.0))?
            .map(|addr| addr.ip())
            .collect();

        Ok(Self {
            make_reconnect_backoff: Box::new(make_reconnect_backoff),
            reconnect_backoff: None,
            url_prototype: url,
            user_agent,
            token,
            state: State::Closed,
            socket_factory,
            waker: None,
            pending_joins: VecDeque::with_capacity(MAX_BUFFERED_MESSAGES),
            pending_messages: VecDeque::with_capacity(MAX_BUFFERED_MESSAGES),
            pending_heartbeat: None,
            _phantom: PhantomData,
            heartbeat: tokio::time::interval(Duration::from_secs(30)),
            next_request_id: 0,
            pending_join_requests: Default::default(),
            login,
            init_req,
            resolved_addresses,
            last_url: None,
        })
    }

    /// Join the provided room.
    ///
    /// If successful, a [`Event::JoinedRoom`] event will be emitted.
    pub fn join(&mut self, topic: impl Into<String>, payload: TInitReq) {
        let (request_id, msg) =
            self.make_control_message(topic, EgressControlMessage::PhxJoin(payload));

        self.pending_joins.push_back(msg);
        self.pending_join_requests
            .insert(request_id, Instant::now());
    }

    /// Send a message to a topic.
    pub fn send(&mut self, topic: impl Into<String>, message: TOutboundMsg) {
        if self.pending_messages.len() > MAX_BUFFERED_MESSAGES {
            self.pending_messages.clear();

            tracing::debug!(
                "Dropping pending messages to portal because we exceeded the maximum of {MAX_BUFFERED_MESSAGES}"
            );
        }

        if self.pending_messages.iter().any(|m| match &m.payload {
            Payload::Message(m) => m == &message,
            Payload::Reply(_) => false,
            Payload::Error(_) => false,
            Payload::Close(_) => false,
            Payload::Disconnect { .. } => false,
        }) {
            tracing::debug!(?message, "Refusing to queue exact duplicate");
            return;
        }

        let request_id = self.fetch_add_request_id();

        self.pending_messages.push_back(PhoenixMessage::new_message(
            topic,
            message,
            Some(request_id),
        ));
    }

    /// Establishes a new connection, dropping the current one if any exists.
    pub fn connect(&mut self, params: TFinish) {
        let url = self.url_prototype.to_url(params);

        if matches!(self.state, State::Connecting(_)) && Some(&url) == self.last_url.as_ref() {
            tracing::debug!("We are already connecting");
            return;
        }

        // 1. Reset the backoff.
        self.reconnect_backoff = None;

        // 2. Set state to `Connecting` without a timer.
        let user_agent = self.user_agent.clone();
        let token = self.token.clone();
        self.state = State::connect(
            url.clone(),
            self.socket_addresses(),
            self.host(),
            user_agent,
            token,
            self.socket_factory.clone(),
        );
        self.last_url = Some(url);

        // 3. In case we were already re-connecting, we need to wake the suspended task.
        if let Some(waker) = self.waker.take() {
            waker.wake();
        }
    }

    pub fn url(&self) -> String {
        self.url_prototype.base_url()
    }

    pub fn host(&self) -> String {
        self.url_prototype.host_and_port().0.to_owned()
    }

    pub fn update_ips(&mut self, ips: Vec<IpAddr>) {
        tracing::debug!(host = %self.host(), current = ?self.resolved_addresses, new = ?ips, "Updating resolved IPs");

        self.resolved_addresses = ips;
    }

    /// Initiate a graceful close of the connection.
    pub fn close(&mut self) -> Result<(), Connecting> {
        tracing::info!("Closing connection to portal");

        match mem::replace(&mut self.state, State::Closed) {
            State::Connecting(_) => return Err(Connecting),
            State::Closing(stream) | State::Connected(stream) => {
                self.state = State::Closing(stream);
            }
            State::Closed | State::Reconnect { .. } => {}
        }

        Ok(())
    }

    pub fn poll(&mut self, cx: &mut Context) -> Poll<Result<Event<TInboundMsg>, Error>> {
        loop {
            // First, check if we are connected.
            let stream = match &mut self.state {
                State::Closed => return Poll::Ready(Ok(Event::Closed)),
                State::Closing(stream) => match stream.poll_close_unpin(cx) {
                    Poll::Ready(Ok(())) => {
                        tracing::info!("Closed websocket connection to portal");

                        self.state = State::Closed;

                        return Poll::Ready(Ok(Event::Closed));
                    }
                    Poll::Ready(Err(e)) => {
                        tracing::warn!("Error while closing websocket: {}", err_with_src(&e));

                        return Poll::Ready(Ok(Event::Closed));
                    }
                    Poll::Pending => return Poll::Pending,
                },
                State::Connected(stream) => stream,
                State::Reconnect { backoff } => {
                    let backoff = *backoff;
                    let socket_addresses = self.socket_addresses();
                    let host = self.host();

                    let secret_url = self
                        .last_url
                        .as_ref()
                        .expect("should have last URL if we receive connection error")
                        .clone();
                    let user_agent = self.user_agent.clone();
                    let token = self.token.clone();
                    let socket_factory = self.socket_factory.clone();

                    self.state = State::Connecting(Box::pin(async move {
                        tokio::time::sleep(backoff).await;
                        create_and_connect_websocket(
                            secret_url,
                            socket_addresses,
                            host,
                            user_agent,
                            token,
                            socket_factory,
                        )
                        .await
                    }));

                    continue;
                }
                State::Connecting(future) => match future.poll_unpin(cx) {
                    Poll::Ready(Ok(stream)) => {
                        self.reconnect_backoff = None;
                        self.heartbeat.reset();
                        self.state = State::Connected(stream);

                        // Clear local state.
                        // Joins are only valid whilst we are connected, so we need to discard any previous ones on reconnect.
                        self.pending_joins.clear();
                        self.pending_join_requests.clear();

                        let (host, _) = self.url_prototype.host_and_port();

                        tracing::info!(%host, "Connected to portal");
                        self.join(self.login, self.init_req.clone());

                        continue;
                    }
                    Poll::Ready(Err(InternalError::WebSocket(tungstenite::Error::Http(r))))
                        if r.status().is_client_error()
                            && r.status() != StatusCode::TOO_MANY_REQUESTS
                            && r.status() != StatusCode::REQUEST_TIMEOUT =>
                    {
                        return Poll::Ready(Err(Error::Client(r.status())));
                    }
                    // Handle 429 and 503 with Retry-After header
                    Poll::Ready(Err(InternalError::WebSocket(tungstenite::Error::Http(r))))
                        if (r.status() == StatusCode::TOO_MANY_REQUESTS
                            || r.status() == StatusCode::SERVICE_UNAVAILABLE)
                            && parse_retry_after(&r).is_some() =>
                    {
                        let duration = parse_retry_after(&r).expect("checked above");
                        let status = r.status();

                        self.state = State::Reconnect { backoff: duration };

                        return Poll::Ready(Ok(Event::RetryAfter {
                            duration,
                            error: anyhow::Error::new(InternalError::WebSocket(
                                tungstenite::Error::Http(r),
                            ))
                            .context(format!(
                                "Server returned {status} with Retry-After: {duration:?}"
                            )),
                        }));
                    }
                    // Unfortunately, the underlying error gets stringified by tungstenite so we cannot match on anything other than the string.
                    Poll::Ready(Err(InternalError::WebSocket(tungstenite::Error::Io(io))))
                        if io.to_string().starts_with("invalid peer certificate") =>
                    {
                        return Poll::Ready(Err(Error::FatalIo(io)));
                    }
                    Poll::Ready(Err(e)) => {
                        let backoff = match self.reconnect_backoff.as_mut() {
                            Some(reconnect_backoff) => reconnect_backoff
                                .next_backoff()
                                .ok_or_else(|| Error::MaxRetriesReached {
                                    final_error: err_with_src(&e).to_string(),
                                })?,
                            None => {
                                self.reconnect_backoff = Some((self.make_reconnect_backoff)());

                                Duration::ZERO
                            }
                        };

                        self.state = State::Reconnect { backoff };

                        return Poll::Ready(Ok(Event::Hiccup {
                            backoff,
                            max_elapsed_time: self
                                .reconnect_backoff
                                .as_ref()
                                .and_then(|b| b.max_elapsed_time),
                            error: anyhow::Error::new(e)
                                .context("Reconnecting to portal on transient error"),
                        }));
                    }
                    Poll::Pending => {
                        // Save a waker in case we want to reset the `Connecting` state while we are waiting.
                        self.waker = Some(cx.waker().clone());
                        return Poll::Pending;
                    }
                },
            };

            // Priority 1: Ensure we are fully flushed.
            if let Err(e) = std::task::ready!(stream.poll_flush_unpin(cx)) {
                self.reconnect_on_transient_error(InternalError::WebSocket(e));
                continue;
            }

            // Priority 2: Keep local buffers small and send pending messages.
            match stream.poll_ready_unpin(cx) {
                Poll::Ready(Ok(())) => {
                    if let Some(heartbeat) = self.pending_heartbeat.take() {
                        match stream.start_send_unpin(Message::Text(heartbeat.clone().into())) {
                            Ok(()) => {
                                tracing::trace!(target: "wire::api::send", %heartbeat);
                            }
                            Err(e) => {
                                self.reconnect_on_transient_error(InternalError::WebSocket(e));
                            }
                        }

                        continue;
                    }

                    if let Some(join) = self.pending_joins.pop_front() {
                        match stream.start_send_unpin(Message::Text(join.clone().into())) {
                            Ok(()) => {
                                tracing::trace!(target: "wire::api::send", %join);

                                self.heartbeat.reset()
                            }
                            Err(e) => {
                                self.pending_joins.push_front(join);
                                self.reconnect_on_transient_error(InternalError::WebSocket(e));
                            }
                        }

                        continue;
                    }

                    if self.pending_join_requests.is_empty() {
                        if let Some(msg) = self.pending_messages.pop_front() {
                            let serialized_msg = serde_json::to_string(&msg)
                                .map_err(io::Error::other)
                                .map_err(Error::FatalIo)?;

                            match stream
                                .start_send_unpin(Message::Text(serialized_msg.clone().into()))
                            {
                                Ok(()) => {
                                    tracing::trace!(target: "wire::api::send", msg = %serialized_msg);

                                    self.heartbeat.reset()
                                }
                                Err(e) => {
                                    self.pending_messages.push_front(msg);
                                    self.reconnect_on_transient_error(InternalError::WebSocket(e));
                                }
                            }

                            continue;
                        }
                    } else if !self.pending_messages.is_empty() {
                        tracing::trace!(
                            requests = ?self.pending_join_requests,
                            "Unable to send message because we are waiting for JOIN requests to complete"
                        );
                    }
                }
                Poll::Ready(Err(e)) => {
                    self.reconnect_on_transient_error(InternalError::WebSocket(e));
                    continue;
                }
                Poll::Pending => {}
            }

            // Priority 3: Handle incoming messages.
            match stream.poll_next_unpin(cx) {
                Poll::Ready(Some(Ok(message))) => {
                    let Ok(message) = message.into_text() else {
                        tracing::warn!("Received non-text message from portal");
                        continue;
                    };

                    tracing::trace!(target: "wire::api::recv", %message);

                    let message =
                        match serde_json::from_str::<PhoenixMessage<TInboundMsg>>(&message) {
                            Ok(m) => m,
                            Err(e) if e.is_io() || e.is_eof() => {
                                self.reconnect_on_transient_error(InternalError::Serde(e));
                                continue;
                            }
                            Err(e) => {
                                tracing::warn!(
                                    "Failed to deserialize message: {}",
                                    err_with_src(&e)
                                );
                                continue;
                            }
                        };

                    match (message.payload, message.reference) {
                        (Payload::Message(msg), _) => {
                            return Poll::Ready(Ok(Event::InboundMessage {
                                topic: message.topic,
                                msg,
                            }));
                        }
                        (Payload::Reply(_), None) => {
                            tracing::warn!("Discarding reply because server omitted reference");
                            continue;
                        }
                        (Payload::Reply(Reply::Error { reason }), Some(req_id)) => {
                            if message.topic == self.login
                                && self.pending_join_requests.contains_key(&req_id)
                            {
                                return Poll::Ready(Err(Error::LoginFailed(reason)));
                            }

                            return Poll::Ready(Ok(Event::ErrorResponse {
                                topic: message.topic,
                                req_id,
                                res: reason,
                            }));
                        }
                        (Payload::Reply(Reply::Ok(OkReply::Message(()))), Some(req_id)) => {
                            return Poll::Ready(Ok(Event::SuccessResponse {
                                topic: message.topic,
                                req_id,
                            }));
                        }
                        (Payload::Reply(Reply::Ok(OkReply::NoMessage(Empty {}))), Some(req_id)) => {
                            if self.pending_join_requests.remove(&req_id).is_some() {
                                tracing::debug!("Joined {} room on portal", message.topic);

                                // For `phx_join` requests, `reply` is empty so we can safely ignore it.
                                return Poll::Ready(Ok(Event::JoinedRoom {
                                    topic: message.topic,
                                }));
                            }

                            tracing::trace!("Received empty reply for request {req_id:?}");

                            continue;
                        }
                        (Payload::Error(Empty {}), reference) => {
                            tracing::debug!(
                                ?reference,
                                topic = &message.topic,
                                "Received empty error response"
                            );
                            continue;
                        }
                        (Payload::Close(Empty {}), _) => {
                            self.reconnect_on_transient_error(InternalError::CloseMessage);
                            continue;
                        }
                        (
                            Payload::Disconnect {
                                reason: DisconnectReason::TokenExpired,
                            },
                            _,
                        ) => {
                            return Poll::Ready(Err(Error::TokenExpired));
                        }
                    }
                }
                Poll::Ready(Some(Err(e))) => {
                    self.reconnect_on_transient_error(InternalError::WebSocket(e));
                    continue;
                }
                Poll::Ready(None) => {
                    self.reconnect_on_transient_error(InternalError::StreamClosed);
                    continue;
                }
                Poll::Pending => {}
            }

            if self
                .pending_join_requests
                .values()
                .any(|sent_at| sent_at.elapsed() > Duration::from_secs(5))
            {
                self.reconnect_on_transient_error(InternalError::RoomJoinTimedOut);
                continue;
            }

            // Priority 4: Handle heartbeats.
            match self.heartbeat.poll_tick(cx) {
                Poll::Ready(_) => {
                    let (_, heartbeat) = self
                        .make_control_message("phoenix", EgressControlMessage::Heartbeat(Empty {}));

                    self.pending_heartbeat = Some(heartbeat);

                    return Poll::Ready(Ok(Event::HeartbeatSent));
                }
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }

    /// Sets the channels state to [`State::Connecting`] with the given error.
    ///
    /// The [`PhoenixChannel::poll`] function will handle the reconnect if appropriate for the given error.
    fn reconnect_on_transient_error(&mut self, e: InternalError) {
        self.state = State::Connecting(future::ready(Err(e)).boxed())
    }

    fn make_control_message(
        &mut self,
        topic: impl Into<String>,
        payload: EgressControlMessage<TInitReq>,
    ) -> (OutboundRequestId, String) {
        let request_id = self.fetch_add_request_id();

        // We don't care about the reply type when serializing
        let msg = serialize_msg(topic, payload, request_id.copy());

        (request_id, msg)
    }

    fn fetch_add_request_id(&mut self) -> OutboundRequestId {
        let id = self.next_request_id;

        self.next_request_id += 1;

        OutboundRequestId(id)
    }

    fn socket_addresses(&self) -> Vec<SocketAddr> {
        let port = self.url_prototype.host_and_port().1;

        self.resolved_addresses
            .iter()
            .map(|ip| SocketAddr::new(*ip, port))
            .collect()
    }
}

#[derive(Debug)]
pub enum Event<TInboundMsg> {
    SuccessResponse {
        topic: String,
        req_id: OutboundRequestId,
    },
    ErrorResponse {
        topic: String,
        req_id: OutboundRequestId,
        res: ErrorReply,
    },
    JoinedRoom {
        topic: String,
    },
    HeartbeatSent,
    /// The server sent us a message, most likely this is a broadcast to all connected clients.
    InboundMessage {
        topic: String,
        msg: TInboundMsg,
    },
    Hiccup {
        backoff: Duration,
        max_elapsed_time: Option<Duration>,
        error: anyhow::Error,
    },
    /// The server sent a 429 or 503 with a Retry-After header specifying when to retry.
    RetryAfter {
        duration: Duration,
        error: anyhow::Error,
    },
    /// The connection was closed successfully.
    Closed,
}

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct PhoenixMessage<T> {
    // TODO: we should use a newtype pattern for topics
    topic: String,
    #[serde(flatten)]
    payload: Payload<T>,
    #[serde(rename = "ref")]
    reference: Option<OutboundRequestId>,
}

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize, Clone)]
#[serde(tag = "event", content = "payload")]
enum Payload<T> {
    #[serde(rename = "phx_reply")]
    Reply(Reply),
    #[serde(rename = "phx_error")]
    Error(Empty),
    #[serde(rename = "phx_close")]
    Close(Empty),
    #[serde(rename = "disconnect")]
    Disconnect { reason: DisconnectReason },
    #[serde(untagged)]
    Message(T),
}

// Awful hack to get serde_json to generate an empty "{}" instead of using "null"
#[derive(Debug, Deserialize, Serialize, PartialEq, Eq, Clone)]
#[serde(deny_unknown_fields)]
struct Empty {}

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize, Clone)]
#[serde(rename_all = "snake_case", tag = "status", content = "response")]
enum Reply {
    Ok(OkReply<()>), // We never expect responses for our requests.
    Error { reason: ErrorReply },
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(untagged)]
enum OkReply<T> {
    Message(T),
    NoMessage(Empty),
}

// TODO: I think this should also be a type-parameter.
/// This represents the info we have about the error
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorReply {
    #[serde(rename = "unmatched topic")]
    UnmatchedTopic,
    InvalidVersion,
    Disabled,
    #[serde(other)]
    Other,
}

impl fmt::Display for ErrorReply {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ErrorReply::UnmatchedTopic => write!(f, "unmatched topic"),
            ErrorReply::InvalidVersion => write!(f, "invalid version"),
            ErrorReply::Disabled => write!(f, "disabled"),
            ErrorReply::Other => write!(f, "other"),
        }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DisconnectReason {
    TokenExpired,
}

impl<T> PhoenixMessage<T> {
    pub fn new_message(
        topic: impl Into<String>,
        payload: T,
        reference: Option<OutboundRequestId>,
    ) -> Self {
        Self {
            topic: topic.into(),
            payload: Payload::Message(payload),
            reference,
        }
    }

    pub fn new_ok_reply(topic: impl Into<String>, reference: Option<OutboundRequestId>) -> Self {
        Self {
            topic: topic.into(),
            payload: Payload::Reply(Reply::Ok(OkReply::Message(()))),
            reference,
        }
    }

    #[cfg(test)]
    fn new_err_reply(
        topic: impl Into<String>,
        reason: ErrorReply,
        reference: Option<OutboundRequestId>,
    ) -> Self {
        Self {
            topic: topic.into(),
            payload: Payload::Reply(Reply::Error { reason }),
            reference,
        }
    }
}

// This is basically the same as tungstenite does but we add some new headers (namely user-agent)
fn make_request(url: Url, host: String, user_agent: String, token: &SecretString) -> Request {
    let mut r = [0u8; 16];
    OsRng.fill_bytes(&mut r);
    let key = base64::engine::general_purpose::STANDARD.encode(r);

    let user_agent = user_agent.replace(|c: char| !c.is_ascii(), "");

    Request::builder()
        .method("GET")
        .header("Host", host)
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header("Sec-WebSocket-Version", "13")
        .header("Sec-WebSocket-Key", key)
        .header("User-Agent", user_agent)
        .header(
            "X-Authorization",
            format!("Bearer {}", token.expose_secret()),
        )
        .uri(url.to_string())
        .body(())
        .expect("should always be able to build a request if we only pass strings to it")
}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
enum EgressControlMessage<T> {
    PhxJoin(T),
    Heartbeat(Empty),
}

fn serialize_msg(
    topic: impl Into<String>,
    payload: impl Serialize,
    request_id: OutboundRequestId,
) -> String {
    serde_json::to_string(&PhoenixMessage::new_message(
        topic,
        payload,
        Some(request_id),
    ))
    .expect("we should always be able to serialize a join topic message")
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, SocketAddrV4};

    use tokio::net::TcpListener;

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

        let msg = serde_json::from_str::<PhoenixMessage<Msg>>(msg).unwrap();

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
        let actual_reply = serde_json::from_str::<Payload<()>>(actual_reply).unwrap();
        let expected_reply = Payload::<()>::Reply(Reply::Error {
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
        let actual_reply = serde_json::from_str::<Payload<()>>(actual_reply).unwrap();
        let expected_reply = Payload::<()>::Close(Empty {});
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
        let actual_reply = serde_json::from_str::<Payload<()>>(actual_reply).unwrap();
        let expected_reply = Payload::<()>::Disconnect {
            reason: DisconnectReason::TokenExpired,
        };
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
        let actual_reply = serde_json::from_str::<Payload<()>>(actual_reply).unwrap();
        let expected_reply = Payload::<()>::Reply(Reply::Error {
            reason: ErrorReply::Other,
        });
        assert_eq!(actual_reply, expected_reply);
    }

    #[test]
    fn invalid_version_reply() {
        let actual_reply = r#"
            {
                "event": "phx_reply",
                "ref": "12",
                "topic": "client",
                "payload":{
                    "status": "error",
                    "response":{
                        "reason": "invalid_version"
                    }
                }
            }
        "#;
        let actual_reply = serde_json::from_str::<Payload<()>>(actual_reply).unwrap();
        let expected_reply = Payload::<()>::Reply(Reply::Error {
            reason: ErrorReply::InvalidVersion,
        });
        assert_eq!(actual_reply, expected_reply);
    }

    #[test]
    fn disabled_err_reply() {
        let json = r#"{"event":"phx_reply","ref":null,"topic":"client","payload":{"status":"error","response":{"reason": "disabled"}}}"#;

        let actual = serde_json::from_str::<PhoenixMessage<()>>(json).unwrap();
        let expected = PhoenixMessage::new_err_reply("client", ErrorReply::Disabled, None);

        assert_eq!(actual, expected)
    }

    #[tokio::test]
    async fn can_sleep_0_ms() {
        tokio::time::sleep(Duration::ZERO).await
    }

    #[tokio::test]
    async fn connect_resolves_even_if_first_address_is_bogus() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();

        tokio::time::timeout(
            Duration::from_secs(5),
            connect(
                vec![
                    SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(192, 168, 0, 1), 80)),
                    listener.local_addr().unwrap(),
                ],
                &socket_factory::tcp,
            ),
        )
        .await
        .unwrap()
        .unwrap();
    }

    #[test]
    fn parse_retry_after_seconds() {
        assert_eq!(
            parse_retry_after_value("120"),
            Some(Duration::from_secs(120))
        );
        assert_eq!(parse_retry_after_value("0"), Some(Duration::from_secs(0)));
        assert_eq!(
            parse_retry_after_value("3600"),
            Some(Duration::from_secs(3600))
        );
    }

    #[test]
    fn parse_retry_after_http_date_in_future() {
        // Create a date 60 seconds in the future
        let future_date = chrono::Utc::now() + chrono::Duration::seconds(60);
        let date_str = future_date.format("%a, %d %b %Y %H:%M:%S GMT").to_string();

        let result = parse_retry_after_value(&date_str);
        assert!(result.is_some(), "should parse future HTTP date");

        let duration = result.unwrap();
        // Allow some tolerance for test execution time
        assert!(
            duration >= Duration::from_secs(58) && duration <= Duration::from_secs(62),
            "duration should be approximately 60 seconds, got {duration:?}"
        );
    }

    #[test]
    fn parse_retry_after_http_date_in_past() {
        // Create a date 60 seconds in the past
        let past_date = chrono::Utc::now() - chrono::Duration::seconds(60);
        let date_str = past_date.format("%a, %d %b %Y %H:%M:%S GMT").to_string();

        let result = parse_retry_after_value(&date_str);
        assert_eq!(result, Some(Duration::ZERO), "past date should return zero");
    }

    #[test]
    fn parse_retry_after_invalid() {
        assert_eq!(parse_retry_after_value("invalid"), None);
        assert_eq!(parse_retry_after_value(""), None);
        assert_eq!(parse_retry_after_value("-1"), None);
        assert_eq!(parse_retry_after_value("12.5"), None);
    }
}
