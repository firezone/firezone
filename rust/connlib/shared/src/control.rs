//! Control protocol related module.
//!
//! This modules contains the logic for handling in and out messages through the control plane.
//! Handling of the message itself can be found in the other lib crates.
//!
//! Entrypoint for this module is [PhoenixChannel].
use std::{marker::PhantomData, time::Duration};

use base64::Engine;
use futures::{
    channel::mpsc::{channel, Receiver, Sender},
    TryStreamExt,
};
use futures_util::{Future, SinkExt, StreamExt, TryFutureExt};
use rand_core::{OsRng, RngCore};
use secrecy::Secret;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use tokio_stream::StreamExt as _;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{self, handshake::client::Request},
};
use tungstenite::Message;
use url::Url;

use crate::{get_user_agent, Error, Result};

const CHANNEL_SIZE: usize = 1_000;
const HEARTBEAT: Duration = Duration::from_secs(30);
const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(35);

pub type Reference = String;

// TODO: Refactor this PhoenixChannel to use the top-level phoenix-channel crate instead.
// See https://github.com/firezone/firezone/issues/2158
pub struct SecureUrl {
    inner: Url,
}
impl SecureUrl {
    pub fn from_url(url: Url) -> Self {
        Self { inner: url }
    }
}
impl secrecy::Zeroize for SecureUrl {
    fn zeroize(&mut self) {
        let placeholder = Url::parse("http://a.com").expect("placeholder URL to be valid");
        let _ = std::mem::replace(&mut self.inner, placeholder);
    }
}
/// Main struct to interact with the control-protocol channel.
///
/// After creating a new `PhoenixChannel` using [PhoenixChannel::new] you need to
/// use [start][PhoenixChannel::start] for the channel to do anything.
///
/// If you want to send something through the channel you need to obtain a [PhoenixSender] through
/// [PhoenixChannel::sender], this will already clone the sender so no need to clone it after you obtain it.
///
/// When [PhoenixChannel::start] is called a new websocket is created that will listen message from the control plane
/// based on the parameters passed on [new][PhoenixChannel::new], from then on any messages sent with a sender
/// obtained by [PhoenixChannel::sender] will be forwarded to the websocket up to the control plane. Ingress messages
/// will be passed on to the `handler` provided in [PhoenixChannel::new].
///
/// The future returned by [PhoenixChannel::start] will finish when the websocket closes (by an error), meaning that if you
/// `await` it, it will block until you use `close` in a [PhoenixSender], the portal close the connection or something goes wrong.
pub struct PhoenixChannel<F, I, R, M> {
    secret_url: Secret<SecureUrl>,
    handler: F,
    sender: Sender<Message>,
    receiver: Receiver<Message>,
    _phantom: PhantomData<(I, R, M)>,
}

// This is basically the same as tungstenite does but we add some new headers (namely user-agent)
fn make_request(secret_url: &Secret<SecureUrl>) -> Result<Request> {
    use secrecy::ExposeSecret;

    let host = secret_url
        .expose_secret()
        .inner
        .host()
        .ok_or(Error::UriError)?;
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
        .header("User-Agent", get_user_agent())
        .uri(secret_url.expose_secret().inner.as_str())
        .body(())?;
    Ok(req)
}

impl<F, Fut, I, R, M> PhoenixChannel<F, I, R, M>
where
    I: DeserializeOwned,
    R: DeserializeOwned,
    M: From<I> + From<R>,
    F: Fn(MessageResult<M>, Option<Reference>) -> Fut,
    Fut: Future<Output = ()> + Send + 'static,
{
    /// Starts the tunnel with the parameters given in [Self::new].
    ///
    // (Note: we could add a generic list of messages but this is easier)
    /// Additionally, you can add a list of topic to join after connection ASAP.
    ///
    /// See [struct-level docs][PhoenixChannel] for more info.
    ///
    // TODO: this is not very elegant but it was the easiest way to do reset the exponential backoff for now
    /// Furthermore, it calls the given callback once it connects to the portal.
    pub async fn start(
        &mut self,
        topics: Vec<String>,
        after_connection_ends: impl FnOnce(),
    ) -> Result<()> {
        tracing::trace!("Trying to connect to portal...");

        let (ws_stream, _) = connect_async(make_request(&self.secret_url)?).await?;

        tracing::trace!("Successfully connected to portal");

        let (mut write, read) = ws_stream.split();

        let mut sender = self.sender();
        let Self {
            handler, receiver, ..
        } = self;

        let process_messages = tokio_stream::StreamExt::map(read.timeout(HEARTBEAT_TIMEOUT), |m| {
            m.map_err(Error::from)?.map_err(Error::from)
        })
        .try_for_each(|message| async {
            Self::message_process(handler, message).await;
            Ok(())
        });

        // Would we like to do write.send_all(futures::stream(Message::text(...))) ?
        // yes.
        // but since write is taken by reference rust doesn't believe this future is sendable anymore
        // so this works for now, since we only use it with 1 topic.
        for topic in topics {
            write
                .send(Message::Text(
                    // We don't care about the reply type when serializing
                    serde_json::to_string(&PhoenixMessage::<_, ()>::new(
                        topic,
                        EgressControlMessage::PhxJoin(Empty {}),
                        None,
                    ))
                    .expect("we should always be able to serialize a join topic message"),
                ))
                .await?;
        }

        // TODO: is Forward cancel safe?
        // I would assume it is and that's the advantage over
        // while let Some(item) = receiver.next().await { write.send(item) } ...
        // but double check this!
        // If it's not cancel safe this means an item can be consumed and never sent.
        // Furthermore can this also happen if write errors out? *that* I'd assume is possible...
        // What option is left? write a new future to forward items.
        // For now we should never assume that an item arrived the portal because we sent it!
        let send_messages = futures::StreamExt::map(receiver, Ok)
            .forward(write)
            .map_err(Error::from);

        let phoenix_heartbeat = tokio::spawn(async move {
            let mut timer = tokio::time::interval(HEARTBEAT);
            loop {
                timer.tick().await;
                let Ok(_) = sender
                    .send("phoenix", EgressControlMessage::Heartbeat(Empty {}))
                    .await
                else {
                    break;
                };
            }
        });

        futures_util::pin_mut!(process_messages, send_messages);
        // processing messages should be quick otherwise it'd block sending messages.
        // we could remove this limitation by spawning a separate task for each of these.
        let result = futures::future::select(process_messages, send_messages)
            .await
            .factor_first()
            .0;
        phoenix_heartbeat.abort();

        after_connection_ends();

        result?;

        Ok(())
    }

    // #[tracing::instrument(level = "trace", skip(handler))]
    async fn message_process(handler: &F, message: tungstenite::Message) {
        tracing::trace!("{message:?}");

        match message.into_text() {
            Ok(m_str) => match serde_json::from_str::<PhoenixMessage<I, R>>(&m_str) {
                Ok(m) => match m.payload {
                    Payload::Message(payload) => handler(Ok(payload.into()), m.reference).await,
                    Payload::Reply(status) => match status {
                        ReplyMessage::PhxReply(phx_reply) => match phx_reply {
                            // TODO: Here we should pass error info to a subscriber
                            PhxReply::Error(info) => {
                                tracing::warn!("Portal error: {info:?}");
                                handler(Err(ErrorReply { error: info }), m.reference).await
                            }
                            PhxReply::Ok(reply) => match reply {
                                OkReply::NoMessage(Empty {}) => {
                                    tracing::trace!(target: "phoenix_status", "Phoenix status message")
                                }
                                OkReply::Message(payload) => {
                                    handler(Ok(payload.into()), m.reference).await
                                }
                            },
                        },
                        ReplyMessage::PhxError(Empty {}) => tracing::error!("Phoenix error"),
                    },
                },
                Err(e) => {
                    tracing::error!(message = "Error deserializing message", message_string =  m_str, error = ?e);
                }
            },
            _ => tracing::error!("Received message that is not text"),
        }
    }

    /// Obtains a new sender that can be used to send message with this [PhoenixChannel] to the portal.
    ///
    /// Note that for the sender to relay any message will need the future returned [PhoenixChannel::start] to be polled (await it),
    /// and [PhoenixChannel::start] takes `&mut self`, meaning you need to get the sender before running [PhoenixChannel::start].
    pub fn sender(&self) -> PhoenixSender {
        PhoenixSender {
            sender: self.sender.clone(),
        }
    }

    /// Obtains a new sender that can be used to send message with this [PhoenixChannel] to the portal for a fixed topic.
    ///
    /// For more info see [PhoenixChannel::sender].
    pub fn sender_with_topic(&self, topic: String) -> PhoenixSenderWithTopic {
        PhoenixSenderWithTopic {
            topic,
            phoenix_sender: self.sender(),
        }
    }

    /// Creates a new [PhoenixChannel] not started yet.
    ///
    /// # Parameters:
    /// - `secret_url`: Portal's websocket uri
    /// - `handler`: The handle that will be called for each received message.
    ///
    /// For more info see [struct-level docs][PhoenixChannel].
    pub fn new(secret_url: Secret<SecureUrl>, handler: F) -> Self {
        let (sender, receiver) = channel(CHANNEL_SIZE);

        Self {
            sender,
            receiver,
            secret_url,
            handler,
            _phantom: PhantomData,
        }
    }
}

/// A result type that is used to communicate to the client/gateway
/// control loop the message received.
pub type MessageResult<M> = std::result::Result<M, ErrorReply>;

/// This struct holds info about an error reply which will be passed
/// to connlib's control plane.
#[derive(Debug, PartialEq, Eq, Deserialize, Serialize, Clone)]
pub struct ErrorReply {
    /// Information of the error
    pub error: ErrorInfo,
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
    reference: Option<String>,
}

impl<T, R> PhoenixMessage<T, R> {
    pub fn new(topic: impl Into<String>, payload: T, reference: Option<String>) -> Self {
        Self {
            topic: topic.into(),
            payload: Payload::Message(payload),
            reference,
        }
    }

    pub fn new_ok_reply(
        topic: impl Into<String>,
        payload: R,
        reference: impl Into<Option<String>>,
    ) -> Self {
        Self {
            topic: topic.into(),
            // There has to be a better way :\
            payload: Payload::Reply(ReplyMessage::PhxReply(PhxReply::Ok(OkReply::Message(
                payload,
            )))),
            reference: reference.into(),
        }
    }

    pub fn new_err_reply(
        topic: impl Into<String>,
        error: ErrorInfo,
        reference: impl Into<Option<String>>,
    ) -> Self {
        Self {
            topic: topic.into(),
            // There has to be a better way :\
            payload: Payload::Reply(ReplyMessage::PhxReply(PhxReply::Error(error))),
            reference: reference.into(),
        }
    }
}

// Awful hack to get serde_json to generate an empty "{}" instead of using "null"
#[derive(Debug, Deserialize, Serialize, PartialEq, Eq, Clone)]
#[serde(deny_unknown_fields)]
struct Empty {}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
enum EgressControlMessage {
    PhxJoin(Empty),
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

/// This represents the info we have about the error
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorInfo {
    Reason(String),
    Offline,
    Disabled,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "status", content = "response")]
enum PhxReply<T> {
    Ok(OkReply<T>),
    Error(ErrorInfo),
}

/// You can use this sender to send messages through a `PhoenixChannel`.
///
/// Messages won't be sent unless [PhoenixChannel::start] is running, internally
/// this sends messages through a future channel that are forwrarded then in [PhoenixChannel] event loop
#[derive(Clone, Debug)]
pub struct PhoenixSender {
    sender: Sender<Message>,
}

/// Like a [PhoenixSender] with a fixed topic for simplicity
///
/// You can obtain it through [PhoenixChannel::sender_with_topic]
/// See [PhoenixSender] docs and use that if you need more control.
#[derive(Clone, Debug)]
pub struct PhoenixSenderWithTopic {
    phoenix_sender: PhoenixSender,
    topic: String,
}

impl PhoenixSenderWithTopic {
    /// Sends a message to the associated topic using a [PhoenixSender]
    ///
    /// See [PhoenixSender::send]
    pub async fn send(&mut self, payload: impl Serialize) -> Result<()> {
        self.phoenix_sender.send(&self.topic, payload).await
    }

    /// Sends a message to the associated topic using a [PhoenixSender] also setting the ref
    ///
    /// See [PhoenixSender::send]
    pub async fn send_with_ref(
        &mut self,
        payload: impl Serialize,
        reference: impl ToString,
    ) -> Result<()> {
        self.phoenix_sender
            .send_with_ref(&self.topic, payload, reference)
            .await
    }
}

impl PhoenixSender {
    async fn send_internal(
        &mut self,
        topic: impl Into<String>,
        payload: impl Serialize,
        reference: Option<String>,
    ) -> Result<()> {
        // We don't care about the reply type when serializing
        let str = serde_json::to_string(&PhoenixMessage::<_, ()>::new(topic, payload, reference))?;
        self.sender.send(Message::text(str)).await?;
        Ok(())
    }

    /// Sends a message upstream to a connected [PhoenixChannel].
    ///
    /// # Parameters
    /// - topic: Phoenix topic
    /// - payload: Message's payload
    pub async fn send(&mut self, topic: impl Into<String>, payload: impl Serialize) -> Result<()> {
        self.send_internal(topic, payload, None).await
    }

    /// Sends a message upstream to a connected [PhoenixChannel] using the given ref number.
    ///
    /// # Parameters
    /// - topic: Phoenix topic
    /// - payload: Message's payload
    /// - reference: Reference number used in the message, if the message has a response that same number will be used
    pub async fn send_with_ref(
        &mut self,
        topic: impl Into<String>,
        payload: impl Serialize,
        reference: impl ToString,
    ) -> Result<()> {
        self.send_internal(topic, payload, Some(reference.to_string()))
            .await
    }

    /// Join a phoenix topic, meaning that after this method is invoked [PhoenixChannel] will
    /// receive messages from that topic, given that upstream accepts you into the given topic.
    pub async fn join_topic(&mut self, topic: impl Into<String>) -> Result<()> {
        self.send(topic, EgressControlMessage::PhxJoin(Empty {}))
            .await
    }

    /// Closes the [PhoenixChannel]
    pub async fn close(&mut self) -> Result<()> {
        self.sender.send(Message::Close(None)).await?;
        self.sender.close().await?;
        Ok(())
    }
}
