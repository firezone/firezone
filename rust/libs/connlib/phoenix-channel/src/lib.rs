#![cfg_attr(test, allow(clippy::unwrap_used))]

mod get_user_agent;
mod login_url;
mod problem_details;
mod tls;

use anyhow::{Context as _, Result};
use futures::stream::FuturesUnordered;
use std::collections::VecDeque;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;
use std::{fmt, future, marker::PhantomData};
use std::{io, mem};
use tokio_tungstenite::tungstenite::protocol::CloseFrame;

use backoff::ExponentialBackoff;
use backoff::ExponentialBackoffBuilder;
use base64::Engine;
use futures::future::BoxFuture;
use futures::{FutureExt, SinkExt, StreamExt};
use itertools::Itertools as _;
use logging::err_with_src;
use problem_details::ProblemDetails;
use secrecy::{ExposeSecret as _, SecretString};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use socket_factory::{SocketFactory, TcpSocket, TcpStream};
use std::task::{Context, Poll, Waker};
use tokio_tungstenite::tungstenite::http::header::RETRY_AFTER;
use tokio_tungstenite::{Connector, client_async_tls_with_config, tungstenite};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream,
    tungstenite::{Message, handshake::client::Request},
};
use url::Url;

pub use get_user_agent::get_user_agent;
pub use login_url::{DeviceInfo, LoginUrl, LoginUrlError, NoParams, PublicKeyParam};
pub use tokio_tungstenite::tungstenite::http::StatusCode;
pub use x509_credential::ClientCertificate;

const MAX_BUFFERED_MESSAGES: usize = 32; // Chosen pretty arbitrarily. If we are connected, these should never build up.

const INITIAL_CONNECT_MAX_ELAPSED_TIME: Duration = Duration::from_secs(15);
const INITIAL_CONNECT_INTERVAL: Duration = Duration::from_secs(1);

/// How often we send a WebSocket ping. The portal closes a connection that sends nothing for 37s.
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);

/// We reconnect when this many pings in a row are unanswered.
const MAX_UNANSWERED_PINGS: usize = 3;

/// Overall timeout for a single connection attempt (TCP + TLS + WebSocket handshake).
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);

/// A connection to the portal over a plain WebSocket.
///
/// Every frame is a JSON text frame `{"event": name, "payload": object}`, in both directions.
/// There is no topic, join or reply: the portal sends `init` once the connection is up.
pub struct PhoenixChannel<TOutboundMsg, TInboundMsg, TFinish> {
    state: State<TOutboundMsg>,
    waker: Option<Waker>,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,

    _phantom: PhantomData<TInboundMsg>,

    // Stored here to allow re-connecting.
    url_prototype: LoginUrl<TFinish>,
    last_url: Option<Url>,
    user_agent: String,
    /// The optional authentication token, sent via X-Authorization when present.
    token: Option<SecretString>,
    /// More secret headers for the upgrade request.
    headers: Vec<(&'static str, SecretString)>,
    make_initial_backoff: Box<dyn Fn() -> ExponentialBackoff + Send>,
    make_reconnect_backoff: Box<dyn Fn() -> ExponentialBackoff + Send>,
    backoff: Option<ExponentialBackoff>,
    was_connected: bool,
}

enum State<TOutboundMsg> {
    Connected(Connected<TOutboundMsg>),
    Connecting(
        BoxFuture<'static, Result<WebSocketStream<MaybeTlsStream<TcpStream>>, InternalError>>,
    ),
    Closing(BoxFuture<'static, Result<()>>),
    Closed,
}

struct Connected<TOutboundMsg> {
    stream: WebSocketStream<MaybeTlsStream<TcpStream>>,

    heartbeat: tokio::time::Interval,
    unanswered_pings: usize,

    pending_messages: VecDeque<TOutboundMsg>,
}

async fn create_and_connect_websocket(
    url: Url,
    addresses: Vec<SocketAddr>,
    host: String,
    user_agent: String,
    token: Option<SecretString>,
    headers: Vec<(&'static str, SecretString)>,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    connect_timeout: Duration,
    tls_client_config: Option<Arc<rustls::ClientConfig>>,
) -> Result<WebSocketStream<MaybeTlsStream<TcpStream>>, InternalError> {
    tracing::debug!(%host, ?addresses, %user_agent, "Connecting to portal");

    let conn = tokio::time::timeout(connect_timeout, async move {
        let duration = Duration::from_secs(5);
        let socket = tokio::time::timeout(duration, connect(addresses.clone(), &*socket_factory))
            .await
            .map_err(|_| {
                InternalError::SocketConnection(
                    addresses
                        .into_iter()
                        .map(|addr| (addr, io::Error::from(io::ErrorKind::TimedOut)))
                        .collect(),
                )
            })??;

        let connector = tls_client_config.map(Connector::Rustls);
        let (stream, _) = client_async_tls_with_config(
            make_request(url, host, user_agent, token.as_ref(), &headers),
            socket,
            None,
            connector,
        )
        .await
        .map_err(InternalError::WebSocket)?;

        Ok(stream)
    })
    .await
    .map_err(|_| InternalError::ConnectTimeout)??;

    Ok(conn)
}

async fn close_websocket(mut stream: WebSocketStream<MaybeTlsStream<TcpStream>>) -> Result<()> {
    stream
        .send(Message::Close(Some(CloseFrame {
            code: tungstenite::protocol::frame::coding::CloseCode::Normal,
            reason: Default::default(),
        })))
        .await
        .context("Failed to send Close frame")?;
    stream.flush().await.context("Failed to flush")?;
    SinkExt::close(&mut stream)
        .await
        .context("failed to close connection")?;

    anyhow::Ok(())
}

async fn connect(
    addresses: Vec<SocketAddr>,
    socket_factory: &dyn SocketFactory<TcpSocket>,
) -> Result<TcpStream, InternalError> {
    if addresses.is_empty() {
        return Err(InternalError::NoAddresses);
    }

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

/// The problem codes the portal reports when it refuses the certificate we presented.
///
/// None of them can be retried into success: the certificate has to be replaced, or the portal
/// reconfigured, before another attempt means anything.
const CERTIFICATE_REJECTION_CODES: &[&str] = &[
    "certificate_revoked",
    "device_identity_conflict",
    "device_untrusted",
    "invalid_certificate",
    "invalid_x509_identity",
    "malformed_cert_issuer",
    "malformed_cert_serial",
    "missing_client_auth_eku",
    "missing_digital_signature_key_usage",
    "no_device_identifiers",
    "no_trust_anchors",
    "outside_validity_window",
    "untrusted_chain",
    "x509_account_disabled",
    "x509_account_not_found",
    "x509_authentication_disabled",
    "x509_authentication_not_found",
    "x509_user_disabled",
    "x509_user_not_authorized",
    "x509_user_not_found",
    "x509_user_type_not_allowed",
];

/// Every variant's `Display` output is shown to the user verbatim.
///
/// These are product copy, not log lines. Word them for someone who has never seen this code.
/// Diagnostics we cannot word for a user go into the variant's source, which only the logs render.
/// A message with a source ends without a full stop, so that the chain reads as one sentence.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Your Firezone sign-in has expired. Sign in again to reconnect.")]
    InvalidToken,
    /// The portal refused to authenticate us for a reason we cannot act on specifically.
    ///
    /// The reason it names is its own wording for the user.
    #[error("The Firezone Portal rejected this device's sign-in: {0}")]
    AuthenticationFailed(String),
    #[error("This device could not sign in with its certificate")]
    ClientCertificateSigningFailed(#[source] BoxError),
    /// The portal refused the X.509 client certificate we presented.
    ///
    /// It words its rejections for the user, so anything we wrap around one only repeats it.
    #[error("{0}")]
    CertificateRejected(String),
    #[error("The connection to the Firezone Portal was lost and could not be restored")]
    MaxRetriesReached {
        #[source]
        final_error: BoxError,
    },
    #[error("Firezone ran into an unrecoverable error")]
    FatalIo(#[source] io::Error),
}

type BoxError = Box<dyn std::error::Error + Send + Sync>;

impl Error {
    /// Returns whether the stored token must be discarded and the user sent through sign-in again.
    ///
    /// This does not report whether the failure was authentication-related in general.
    /// Only failures that render the token itself unusable require a new sign-in.
    pub fn requires_sign_in(&self) -> bool {
        match self {
            Error::InvalidToken => true,
            // The portal rejected us without naming the token, so a new one is not known to help.
            Error::AuthenticationFailed(_) => false,
            Error::ClientCertificateSigningFailed(_) => false,
            // The certificate is the credential the portal refused, so a new token cannot help.
            Error::CertificateRejected(_) => false,
            Error::MaxRetriesReached { .. } => false,
            Error::FatalIo(_) => false,
        }
    }

    /// Classifies a rejected connection attempt by the reason the portal reported.
    ///
    /// Returns `None` when nothing in the response marks the failure as permanent, so the
    /// caller keeps retrying. The portal names permanent rejections with a problem code:
    /// an unusable token, or a refused client certificate, which it answers with 403 and
    /// 409 rather than 401. A 401 without a specific code maps to
    /// [`Error::AuthenticationFailed`], as does one without problem details at all,
    /// e.g. an error page from an intermediary proxy.
    fn from_rejection(response: &tungstenite::handshake::client::Response) -> Option<Self> {
        let problem = ProblemDetails::from_response(response).unwrap_or_default();
        let detail = problem
            .detail
            .unwrap_or_else(|| "no reason provided".to_owned());

        match problem.code.as_deref() {
            Some("invalid_token" | "missing_token") => Some(Error::InvalidToken),
            Some(code) if CERTIFICATE_REJECTION_CODES.contains(&code) => {
                Some(Error::CertificateRejected(detail))
            }
            _ if response.status() == StatusCode::UNAUTHORIZED => {
                Some(Error::AuthenticationFailed(detail))
            }
            _ => None,
        }
    }
}

#[derive(Debug)]
enum InternalError {
    WebSocket(tungstenite::Error),
    Serde(serde_json::Error),
    WsClose(Option<CloseFrame>),
    StreamClosed,
    SocketConnection(Vec<(SocketAddr, io::Error)>),
    NoAddresses,
    ConnectTimeout,
    TooManyUnansweredHeartbeats,
}

impl InternalError {
    /// Extracts the message of a client-certificate signing failure that happened during the TLS handshake.
    ///
    /// Signing with a platform key can fail for good, e.g. because the user declined the keystore prompt.
    /// Retrying such a connection is pointless, so it must not be mistaken for one of the many transient IO errors.
    fn client_certificate_signing_error(&self) -> Option<String> {
        let Self::WebSocket(tungstenite::Error::Io(error)) = self else {
            return None;
        };
        let tls_error = error.get_ref()?.downcast_ref::<rustls::Error>()?;
        let rustls::Error::Other(other) = tls_error else {
            return None;
        };

        let error = other.0.downcast_ref::<x509_credential::SigningError>()?;

        Some(error.to_string())
    }

    /// Parses a Retry-After header value into a Duration.
    ///
    /// The header can be either:
    /// - A number of seconds (e.g., "120")
    /// - An HTTP date in IMF-fixdate format (e.g., "Wed, 21 Oct 2015 07:28:00 GMT")
    pub(crate) fn parse_retry_after_header(&self) -> Option<Duration> {
        let Self::WebSocket(tungstenite::Error::Http(response)) = self else {
            return None;
        };

        let header = response.headers().get(RETRY_AFTER)?;
        let value = header.to_str().ok()?;
        let duration = parse_retry_after_value(value)?;

        Some(duration)
    }
}

fn parse_retry_after_value(value: &str) -> Option<Duration> {
    // Try parsing as seconds first (most common for 429 responses)
    if let Ok(seconds) = value.parse::<u64>() {
        return Some(Duration::from_secs(seconds));
    }

    // Try parsing as HTTP date (IMF-fixdate format: "Wed, 21 Oct 2015 07:28:00 GMT")
    if let Ok(retry_at) = jiff::fmt::rfc2822::DateTimeParser::new().parse_timestamp(value) {
        let duration = retry_at
            .duration_since(jiff::Timestamp::now())
            .try_into()
            .unwrap_or(Duration::ZERO);

        return Some(duration);
    }

    None
}

impl fmt::Display for InternalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            InternalError::WebSocket(_) => write!(f, "websocket connection failed"),
            InternalError::Serde(_) => write!(f, "failed to deserialize message"),
            InternalError::WsClose(Some(frame)) => {
                write!(f, "portal sent websocket close frame: {frame}")
            }
            InternalError::WsClose(None) => {
                write!(f, "portal sent empty websocket close frame")
            }
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
            InternalError::NoAddresses => write!(f, "no IP addresses available"),
            InternalError::ConnectTimeout => write!(f, "connection to portal timed out"),
            InternalError::TooManyUnansweredHeartbeats => {
                write!(f, "too many pings were unanswered")
            }
        }
    }
}

impl std::error::Error for InternalError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            InternalError::WebSocket(e) => Some(e),
            InternalError::Serde(e) => Some(e),
            InternalError::SocketConnection(_) => None,
            InternalError::WsClose(_) => None,
            InternalError::StreamClosed => None,
            InternalError::NoAddresses => None,
            InternalError::ConnectTimeout => None,
            InternalError::TooManyUnansweredHeartbeats => None,
        }
    }
}

/// Recovers the body of an HTTP error response from a portal connection error.
pub fn http_error_body(error: &anyhow::Error) -> Option<String> {
    use anyhow::ErrorExt as _;

    let tungstenite::Error::Http(response) = error.any_downcast_ref::<tungstenite::Error>()? else {
        return None;
    };

    response
        .body()
        .as_deref()
        .map(|body| String::from_utf8_lossy(body).into_owned())
}

#[derive(Debug, thiserror::Error)]
#[error("Cannot close websocket while we are connecting")]
pub struct Connecting;

#[derive(Debug, thiserror::Error)]
#[error("Not connected")]
pub struct NotConnected<T>(pub T);

impl<TOutboundMsg, TInboundMsg, TFinish> PhoenixChannel<TOutboundMsg, TInboundMsg, TFinish>
where
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
        token: impl Into<Option<SecretString>>,
        user_agent: String,
        make_reconnect_backoff: impl Fn() -> ExponentialBackoff + Send + 'static,
        socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    ) -> Self {
        Self {
            make_initial_backoff: Box::new(make_initial_backoff),
            make_reconnect_backoff: Box::new(make_reconnect_backoff),
            backoff: None,
            was_connected: false,
            url_prototype: url,
            user_agent,
            token: token.into(),
            headers: Vec::new(),
            state: State::Closed,
            socket_factory,
            waker: None,
            _phantom: PhantomData,
            last_url: None,
        }
    }

    /// Sends a secret header with every upgrade request.
    pub fn with_header(mut self, name: &'static str, value: SecretString) -> Self {
        self.headers.push((name, value));
        self
    }

    /// Sends a message to the portal.
    pub fn send(&mut self, message: TOutboundMsg) -> Result<(), NotConnected<TOutboundMsg>> {
        let State::Connected(Connected {
            pending_messages, ..
        }) = &mut self.state
        else {
            return Err(NotConnected(message));
        };

        if pending_messages.contains(&message) {
            tracing::debug!(?message, "Refusing to queue exact duplicate");
            return Ok(());
        }

        pending_messages.push_back(message);

        Ok(())
    }

    /// Establishes a new connection, dropping the current one if any exists.
    pub fn connect(&mut self, addresses: Vec<IpAddr>, backoff: Duration, params: TFinish) {
        let url = self.url_prototype.to_url(params);

        let closing = match std::mem::replace(&mut self.state, State::Closed) {
            State::Closing(closing) => closing,
            State::Connected(connected) => close_websocket(connected.stream).boxed(),
            State::Connecting(_) | State::Closed => std::future::ready(Ok(())).boxed(),
        };

        self.state = State::Connecting(Box::pin({
            let url = url.clone();
            let addresses = addresses
                .into_iter()
                .chain(self.host().parse::<IpAddr>().ok())
                .unique()
                .map(|ip| SocketAddr::new(ip, self.port()))
                .collect();
            let host = self.host();
            let user_agent = self.user_agent.clone();
            let token = self.token.clone();
            let headers = self.headers.clone();
            let socket_factory = self.socket_factory.clone();
            let tls_client_config = self.url_prototype.tls_client_config();

            async move {
                if let Err(e) = closing.await {
                    tracing::debug!("Failed to gracefully close connection: {e:#}");
                }

                tokio::time::sleep(backoff).await;
                create_and_connect_websocket(
                    url,
                    addresses,
                    host,
                    user_agent,
                    token,
                    headers,
                    socket_factory,
                    CONNECT_TIMEOUT,
                    tls_client_config,
                )
                .await
            }
        }));
        self.last_url = Some(url);

        // In case we were already re-connecting, we need to wake the suspended task.
        if let Some(waker) = self.waker.take() {
            waker.wake();
        }

        if backoff.is_zero() {
            self.backoff = None;
        }
    }

    pub fn url(&self) -> String {
        self.url_prototype.base_url()
    }

    pub fn host(&self) -> String {
        self.url_prototype.host_and_port().0.to_owned()
    }

    fn port(&self) -> u16 {
        self.url_prototype.host_and_port().1
    }

    /// Initiate a graceful close of the connection.
    pub fn close(&mut self) -> Result<(), Connecting> {
        tracing::info!("Closing connection to portal");

        match mem::replace(&mut self.state, State::Closed) {
            State::Connecting(_) => return Err(Connecting),
            State::Connected(Connected { stream, .. }) => {
                self.state = State::Closing(close_websocket(stream).boxed());
            }
            State::Closing(stream) => {
                self.state = State::Closing(stream);
            }
            State::Closed => {}
        }

        Ok(())
    }

    pub fn poll(&mut self, cx: &mut Context) -> Poll<Result<Event<TInboundMsg>, Error>> {
        loop {
            // First, check if we are connected.
            let Connected {
                stream,
                heartbeat,
                unanswered_pings,
                pending_messages,
            } = match &mut self.state {
                State::Connected(stream) => stream,
                State::Closed => return Poll::Ready(Ok(Event::Closed)),
                State::Closing(future) => match std::task::ready!(future.poll_unpin(cx)) {
                    Ok(()) => {
                        tracing::info!("Closed websocket connection to portal");
                        self.state = State::Closed;

                        return Poll::Ready(Ok(Event::Closed));
                    }
                    Err(e) => {
                        tracing::info!("Error while closing websocket connection to portal: {e:#}");
                        self.state = State::Closed;

                        return Poll::Ready(Ok(Event::Closed));
                    }
                },
                State::Connecting(future) => match future.poll_unpin(cx) {
                    Poll::Ready(Ok(stream)) => {
                        self.state = State::Connected(Connected {
                            stream,
                            heartbeat: tokio::time::interval_at(
                                tokio::time::Instant::now() + HEARTBEAT_INTERVAL,
                                HEARTBEAT_INTERVAL,
                            ),
                            unanswered_pings: 0,
                            pending_messages: VecDeque::with_capacity(MAX_BUFFERED_MESSAGES),
                        });
                        self.backoff = None;
                        self.was_connected = true;

                        let (host, _) = self.url_prototype.host_and_port();
                        tracing::info!(%host, "Connected to portal");

                        return Poll::Ready(Ok(Event::Connected));
                    }
                    Poll::Ready(Err(InternalError::WebSocket(tungstenite::Error::Http(ref r))))
                        if let Some(error) = Error::from_rejection(r) =>
                    {
                        self.state = State::Closed;
                        return Poll::Ready(Err(error));
                    }
                    Poll::Ready(Err(e))
                        if let Some(message) = e.client_certificate_signing_error() =>
                    {
                        self.state = State::Closed;
                        return Poll::Ready(Err(Error::ClientCertificateSigningFailed(
                            message.into(),
                        )));
                    }
                    Poll::Ready(Err(e)) => {
                        let backoff = match e.parse_retry_after_header() {
                            Some(duration) => duration,
                            None => {
                                let backoff =
                                    self.backoff.get_or_insert_with(if self.was_connected {
                                        &self.make_reconnect_backoff
                                    } else {
                                        &self.make_initial_backoff
                                    });

                                let Some(duration) = backoff.next_backoff() else {
                                    return Poll::Ready(Err(Error::MaxRetriesReached {
                                        final_error: Box::new(e),
                                    }));
                                };

                                duration
                            }
                        };
                        self.state = State::Closed;

                        return Poll::Ready(Ok(Event::Hiccup {
                            backoff,
                            max_elapsed_time: self
                                .backoff
                                .as_ref()
                                .and_then(|b| b.max_elapsed_time),
                            error: anyhow::Error::new(e).context("Connection hiccup"),
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
                self.handle_internal_error(InternalError::WebSocket(e));
                continue;
            }

            // Priority 2: Keep local buffers small and send pending messages.
            match stream.poll_ready_unpin(cx) {
                Poll::Ready(Ok(())) => {
                    if heartbeat.poll_tick(cx).is_ready() {
                        if *unanswered_pings >= MAX_UNANSWERED_PINGS {
                            self.handle_internal_error(InternalError::TooManyUnansweredHeartbeats);
                            continue;
                        }

                        match stream.start_send_unpin(Message::Ping(Default::default())) {
                            Ok(()) => {
                                *unanswered_pings += 1;
                                tracing::trace!(target: "wire::api::send", "ping");
                            }
                            Err(e) => {
                                self.handle_internal_error(InternalError::WebSocket(e));
                            }
                        }

                        continue;
                    }

                    if let Some(msg) = pending_messages.pop_front() {
                        let serialized_msg = serde_json::to_string(&msg)
                            .map_err(io::Error::other)
                            .map_err(Error::FatalIo)?;

                        match stream.start_send_unpin(Message::Text(serialized_msg.clone().into()))
                        {
                            Ok(()) => {
                                tracing::trace!(target: "wire::api::send", msg = %serialized_msg);
                            }
                            Err(e) => {
                                pending_messages.push_front(msg);
                                self.handle_internal_error(InternalError::WebSocket(e));
                            }
                        }

                        continue;
                    }
                }
                Poll::Ready(Err(e)) => {
                    self.handle_internal_error(InternalError::WebSocket(e));
                    continue;
                }
                Poll::Pending => {}
            }

            // Priority 3: Handle incoming messages.
            match stream.poll_next_unpin(cx) {
                Poll::Ready(Some(Ok(Message::Close(frame)))) => {
                    // Grab ownership of the `stream`.
                    let mut stream = match std::mem::replace(&mut self.state, State::Closed) {
                        State::Connected(Connected { stream, .. }) => stream,
                        State::Connecting(_) | State::Closing(_) | State::Closed => {
                            // Defense-in-depth: This should not happen but never know what kind of bugs we might introduce in the future.
                            debug_assert!(
                                false,
                                "Should be in Connected after receiving Close frame"
                            );
                            self.handle_internal_error(InternalError::WsClose(frame));
                            continue;
                        }
                    };

                    // If an endpoint receives a Close frame and did not previously send a Close frame,
                    // the endpoint MUST send a Close frame in response.
                    // See <https://datatracker.ietf.org/doc/html/rfc6455#section-5.5.1>.
                    self.state = State::Connecting(
                        async move {
                            let _ = stream.send(Message::Close(frame.clone())).await;
                            let _ = stream.flush().await;
                            let _ = SinkExt::close(&mut stream).await;

                            Err(InternalError::WsClose(frame))
                        }
                        .boxed(),
                    );
                    continue;
                }
                Poll::Ready(Some(Ok(Message::Text(message)))) => {
                    tracing::trace!(target: "wire::api::recv", %message);

                    match serde_json::from_str::<Inbound<TInboundMsg>>(&message) {
                        Ok(Inbound::Message(msg)) => {
                            return Poll::Ready(Ok(Event::Message { msg }));
                        }
                        Ok(Inbound::Disconnect {
                            reason: DisconnectReason::TokenExpired,
                        }) => {
                            return Poll::Ready(Err(Error::InvalidToken));
                        }
                        Err(e) if e.is_io() || e.is_eof() => {
                            self.handle_internal_error(InternalError::Serde(e));
                            continue;
                        }
                        Err(e) => {
                            tracing::warn!("Failed to deserialize message: {}", err_with_src(&e));
                            continue;
                        }
                    }
                }
                Poll::Ready(Some(Ok(Message::Binary(_)))) => {
                    tracing::warn!("Received unexpected binary message from portal");
                    continue;
                }
                Poll::Ready(Some(Ok(Message::Pong(_)))) => {
                    *unanswered_pings = 0;
                    continue;
                }
                // tungstenite answers pings itself.
                Poll::Ready(Some(Ok(Message::Ping(_) | Message::Frame(_)))) => {
                    continue;
                }
                Poll::Ready(Some(Err(e))) => {
                    self.handle_internal_error(InternalError::WebSocket(e));
                    continue;
                }
                Poll::Ready(None) => {
                    self.handle_internal_error(InternalError::StreamClosed);
                    continue;
                }
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }

    /// Sets the channels state to [`State::Connecting`] with the given error.
    ///
    /// The [`PhoenixChannel::poll`] function will handle the error appropriately.
    fn handle_internal_error(&mut self, e: InternalError) {
        self.state = State::Connecting(future::ready(Err(e)).boxed())
    }
}

fn make_initial_backoff() -> ExponentialBackoff {
    ExponentialBackoffBuilder::default()
        .with_initial_interval(INITIAL_CONNECT_INTERVAL)
        .with_max_interval(INITIAL_CONNECT_INTERVAL)
        .with_multiplier(1.0)
        .with_randomization_factor(0.0)
        .with_max_elapsed_time(Some(INITIAL_CONNECT_MAX_ELAPSED_TIME))
        .build()
}

#[derive(Debug)]
pub enum Event<TInboundMsg> {
    /// The server sent us a message.
    Message { msg: TInboundMsg },
    /// The connection failed with a transient error.
    ///
    /// You must call [`PhoenixChannel::connect`] after this (or discard the instance).
    Hiccup {
        backoff: Duration,
        max_elapsed_time: Option<Duration>,
        error: anyhow::Error,
    },
    /// The connection was closed successfully.
    Closed,
    /// The portal connection was established.
    Connected,
}

/// A message from the portal.
#[derive(Debug, PartialEq, Eq, Deserialize)]
#[serde(tag = "event", content = "payload")]
enum Inbound<T> {
    #[serde(rename = "disconnect")]
    Disconnect { reason: DisconnectReason },
    #[serde(untagged)]
    Message(T),
}

#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum DisconnectReason {
    TokenExpired,
}

// This is basically the same as tungstenite does but we add some new headers (namely user-agent)
fn make_request(
    url: Url,
    host: String,
    user_agent: String,
    token: Option<&SecretString>,
    headers: &[(&'static str, SecretString)],
) -> Request {
    let r: [u8; 16] = rand::random();
    let key = base64::engine::general_purpose::STANDARD.encode(r);

    let user_agent = user_agent.replace(|c: char| !c.is_ascii(), "");
    let mut builder = Request::builder()
        .method("GET")
        .header("Host", host)
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header("Sec-WebSocket-Version", "13")
        .header("Sec-WebSocket-Key", key)
        .header("User-Agent", user_agent);

    if let Some(token) = token {
        let token = token
            .expose_secret()
            .replace(|c: char| c.is_whitespace(), "");

        builder = builder.header("X-Authorization", format!("Bearer {token}"));
    }

    for (name, value) in headers {
        builder = builder.header(
            *name,
            value.expose_secret().replace(char::is_whitespace, ""),
        );
    }

    builder
        .uri(url.to_string())
        .body(())
        .expect("should always be able to build a request if we only pass strings to it")
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, SocketAddrV4};

    #[test]
    fn extracts_client_certificate_signing_error() {
        let tls_error = rustls::Error::Other(rustls::OtherError(Arc::new(
            x509_credential::SigningError::AccessDenied(
                "provider interaction is unavailable".to_owned(),
            ),
        )));
        let error = InternalError::WebSocket(tungstenite::Error::Io(io::Error::other(tls_error)));

        assert_eq!(
            error.client_certificate_signing_error().as_deref(),
            Some(
                "the keystore refused to use the private key: provider interaction is unavailable"
            )
        );
    }

    #[derive(Deserialize, PartialEq, Debug)]
    #[serde(rename_all = "snake_case", tag = "event", content = "payload")] // This line makes it all work.
    enum Msg {
        Shout { hello: String },
    }

    use tokio::net::TcpListener;

    use super::*;

    #[test]
    fn http_error_body_recovers_response_body() {
        let response = tungstenite::http::Response::builder()
            .status(StatusCode::SERVICE_UNAVAILABLE)
            .body(Some(b"service down".to_vec()))
            .unwrap();
        let error = anyhow::Error::new(tungstenite::Error::Http(Box::new(response)))
            .context("Connection hiccup");

        assert_eq!(http_error_body(&error).as_deref(), Some("service down"));
    }

    #[test]
    fn http_error_body_is_none_for_non_http_errors() {
        let error = anyhow::Error::msg("some other failure").context("Connection hiccup");

        assert_eq!(http_error_body(&error), None);
    }

    #[test]
    fn unauthorized_with_invalid_token_code_blames_the_token() {
        let response = tungstenite::http::Response::builder()
            .status(StatusCode::UNAUTHORIZED)
            .header("content-type", "application/problem+json; charset=utf-8")
            .body(Some(
                br#"{"title":"Unauthorized","status":401,"detail":"Invalid token","code":"invalid_token"}"#.to_vec(),
            ))
            .unwrap();

        let error = Error::from_rejection(&response).expect("a 401 naming the token is terminal");

        assert!(matches!(error, Error::InvalidToken), "got {error:?}");
    }

    #[test]
    fn unauthorized_without_code_does_not_blame_the_token() {
        let response = tungstenite::http::Response::builder()
            .status(StatusCode::UNAUTHORIZED)
            .header("content-type", "application/problem+json; charset=utf-8")
            .body(Some(
                br#"{"title":"Unauthorized","status":401,"detail":"Invalid token"}"#.to_vec(),
            ))
            .unwrap();

        let error = Error::from_rejection(&response).expect("a plain 401 is terminal");

        assert!(!error.requires_sign_in());
        assert_eq!(
            error.to_string(),
            "The Firezone Portal rejected this device's sign-in: Invalid token"
        );
    }

    #[test]
    fn can_deserialize_inbound_message() {
        let msg = r#"{"event": "shout", "payload": {"hello": "world"}}"#;

        let msg = serde_json::from_str::<Inbound<Msg>>(msg).unwrap();

        assert_eq!(
            msg,
            Inbound::Message(Msg::Shout {
                hello: "world".to_owned()
            })
        );
    }

    #[test]
    fn token_expired() {
        let msg = r#"{"event": "disconnect", "payload": {"reason": "token_expired"}}"#;

        let msg = serde_json::from_str::<Inbound<Msg>>(msg).unwrap();

        assert_eq!(
            msg,
            Inbound::Disconnect {
                reason: DisconnectReason::TokenExpired
            }
        );
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
        let future_date = jiff::Timestamp::now() + jiff::SignedDuration::from_secs(60);
        let date_str = future_date
            .strftime("%a, %d %b %Y %H:%M:%S GMT")
            .to_string();

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
        let past_date = jiff::Timestamp::now() - jiff::SignedDuration::from_secs(60);
        let date_str = past_date.strftime("%a, %d %b %Y %H:%M:%S GMT").to_string();

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

    #[tokio::test]
    async fn connect_times_out_when_handshake_hangs() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        // Accept the connection but never respond, simulating a hung TLS/WS handshake.
        tokio::spawn(async move {
            let (_socket, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_secs(3600)).await;
        });

        let url = Url::parse(&format!("ws://127.0.0.1:{}/websocket", addr.port())).unwrap();
        let result = create_and_connect_websocket(
            url,
            vec![addr],
            "127.0.0.1".to_string(),
            "test-agent".to_string(),
            Some(SecretString::from("test-token".to_string())),
            Vec::new(),
            Arc::new(socket_factory::tcp),
            Duration::from_secs(2),
            None,
        )
        .await;

        assert!(
            matches!(result, Err(InternalError::ConnectTimeout)),
            "Expected ConnectTimeout"
        );
    }

    #[test]
    fn make_request_strips_newline_from_token() {
        let request = make_request(
            Url::parse("ws://example.com/websocket").unwrap(),
            "example.com".to_string(),
            "test-agent".to_string(),
            Some(&SecretString::from(
                "valid-token-part\ninjected".to_string(),
            )),
            &[],
        );

        assert_eq!(
            request.headers()["X-Authorization"],
            "Bearer valid-token-partinjected"
        );
    }

    #[test]
    fn make_request_strips_carriage_return_from_token() {
        let request = make_request(
            Url::parse("ws://example.com/websocket").unwrap(),
            "example.com".to_string(),
            "test-agent".to_string(),
            Some(&SecretString::from(
                "valid-token-part\rinjected".to_string(),
            )),
            &[],
        );

        assert_eq!(
            request.headers()["X-Authorization"],
            "Bearer valid-token-partinjected"
        );
    }

    #[test]
    fn make_request_omits_authorization_without_token() {
        let request = make_request(
            Url::parse("ws://example.com/websocket").unwrap(),
            "example.com".to_string(),
            "test-agent".to_string(),
            None,
            &[],
        );

        assert!(!request.headers().contains_key("X-Authorization"));
    }

    #[test]
    fn make_request_accepts_valid_token() {
        let request = make_request(
            Url::parse("ws://example.com/websocket").unwrap(),
            "example.com".to_string(),
            "test-agent".to_string(),
            Some(&SecretString::from(
                "a-perfectly-valid.token_123".to_string(),
            )),
            &[],
        );

        assert_eq!(
            request.headers()["X-Authorization"],
            "Bearer a-perfectly-valid.token_123"
        );
    }
}
