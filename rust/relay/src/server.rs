use anyhow::Result;
use bytecodec::{DecodeExt, EncodeExt};
use rand::Rng;
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::hash::Hash;
use std::net::SocketAddr;
use std::time::Duration;
use stun_codec::rfc5389::attributes::{ErrorCode, MessageIntegrity, XorMappedAddress};
use stun_codec::rfc5389::errors::BadRequest;
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::attributes::{Lifetime, RequestedTransport, XorRelayAddress};
use stun_codec::rfc5766::errors::{AllocationMismatch, InsufficientCapacity};
use stun_codec::rfc5766::methods::ALLOCATE;
use stun_codec::{Message, MessageClass, MessageDecoder, MessageEncoder, TransactionId};

/// A sans-IO STUN & TURN server.
///
/// A server is bound to a particular address kind (either IPv4 or IPv6).
/// If you listen on both interfaces or several ports, you should create multiple instances of [`Server`].
///
/// It also assumes it has complete ownership over the port range 49152 - 65535.
pub struct Server<TAddressKind> {
    decoder: MessageDecoder<Attribute>,
    encoder: MessageEncoder<Attribute>,

    local_address: TAddressKind,

    /// All client allocations, indexed by client's socket address.
    allocations: HashMap<TAddressKind, Allocation>,

    used_ports: HashSet<u16>,
}

/// See <https://www.rfc-editor.org/rfc/rfc8656#name-requested-transport>
const UDP_TRANSPORT: u8 = 17;

/// The maximum number of ports available for allocation.
const MAX_AVAILABLE_PORTS: u16 = 65535 - 49152;

/// The maximum lifetime of an allocation.
const MAX_ALLOCATION_LIFETIME: Duration = Duration::from_secs(3600);

/// The default lifetime of an allocation.
///
/// TODO: This has been chosen at random by Thomas. Revisit if it makes sense.
const DEFAULT_ALLOCATION_LIFETIME: Duration = Duration::from_secs(600);

impl<TAddressKind> Server<TAddressKind>
where
    TAddressKind: fmt::Display + Into<SocketAddr> + Copy + Eq + Hash,
{
    pub fn new(local_address: TAddressKind) -> Self {
        // TODO: Verify that local_address isn't a multicast address.

        Self {
            decoder: Default::default(),
            encoder: Default::default(),
            local_address,
            allocations: Default::default(),
            used_ports: Default::default(),
        }
    }

    /// Process the bytes received from one node and optionally return bytes to send back to the same or a different node.
    pub fn handle_received_bytes(
        &mut self,
        bytes: &[u8],
        sender: TAddressKind,
    ) -> Result<Option<(Vec<u8>, TAddressKind)>> {
        let Ok(message) = self.decoder.decode_from_bytes(bytes)? else {
            tracing::trace!("received broken STUN message from {sender}");
            return Ok(None);
        };

        tracing::trace!("Received message {message:?} from {sender}");

        let Some((recipient, response)) = self.handle_message(message, sender) else {
            return Ok(None);
        };

        tracing::trace!("Sending message {response:?} to {recipient}");

        let bytes = self.encoder.encode_into_bytes(response)?;

        Ok(Some((bytes, recipient)))
    }

    fn handle_message(
        &mut self,
        message: Message<Attribute>,
        sender: TAddressKind,
    ) -> Option<(TAddressKind, Message<Attribute>)> {
        if message.class() == MessageClass::Request && message.method() == BINDING {
            tracing::debug!("Received STUN binding request from: {sender}");

            return Some(self.handle_binding_request(message, sender));
        }

        if message.class() == MessageClass::Request && message.method() == ALLOCATE {
            tracing::debug!("Received TURN allocate request from: {sender}");

            let transaction_id = message.transaction_id();

            let (recipient, message) = self
                .handle_allocate_request(message, sender)
                .unwrap_or_else(|e| (sender, allocate_error(transaction_id, e)));

            return Some((recipient, message));
        }

        tracing::debug!(
            "Unhandled message of type {:?} and method {:?} from {}",
            message.class(),
            message.method(),
            sender
        );

        None
    }

    fn handle_binding_request(
        &self,
        message: Message<Attribute>,
        sender: TAddressKind,
    ) -> (TAddressKind, Message<Attribute>) {
        let mut message = Message::new(
            MessageClass::SuccessResponse,
            BINDING,
            message.transaction_id(),
        );
        message.add_attribute(XorMappedAddress::new(sender.into()).into());

        (sender, message)
    }

    /// Handle a TURN allocate request.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-receiving-an-allocate-reque> for details.
    fn handle_allocate_request(
        &mut self,
        message: Message<Attribute>,
        sender: TAddressKind,
    ) -> Result<(TAddressKind, Message<Attribute>), ErrorCode> {
        if self.allocations.contains_key(&sender) {
            return Err(AllocationMismatch.into());
        }

        if self.used_ports.len() == MAX_AVAILABLE_PORTS as usize {
            return Err(InsufficientCapacity.into());
        }

        let requested_transport = message
            .get_attribute::<RequestedTransport>()
            .ok_or(BadRequest)?;

        if requested_transport.protocol() != UDP_TRANSPORT {
            return Err(BadRequest.into());
        }

        let requested_lifetime = message.get_attribute::<Lifetime>();

        let effective_lifetime = compute_effective_lifetime(requested_lifetime);

        // TODO: Do we need to handle DONT-FRAGMENT?
        // TODO: Do we need to handle EVEN/ODD-PORT?

        let relay_address = self.new_relay_address();

        self.allocations.insert(
            sender,
            Allocation {
                address: relay_address,
            },
        );

        tracing::info!("Created new allocation for {sender} with address {relay_address} and lifetime {}s", effective_lifetime.lifetime().as_secs());

        let mut message = Message::new(
            MessageClass::SuccessResponse,
            ALLOCATE,
            message.transaction_id(),
        );

        message.add_attribute(XorRelayAddress::new(relay_address).into());
        message.add_attribute(XorMappedAddress::new(sender.into()).into());
        message.add_attribute(effective_lifetime.into());

        Ok((sender, message))
    }

    fn new_relay_address(&mut self) -> SocketAddr {
        // First, find an unused port.

        assert!(
            self.used_ports.len() < MAX_AVAILABLE_PORTS as usize,
            "No more ports available; this would loop forever"
        );

        let port = loop {
            let candidate = rand::thread_rng().gen_range(49152..65535);

            if !self.used_ports.contains(&candidate) {
                self.used_ports.insert(candidate);
                break candidate;
            }
        };

        // Second, take the local address of the server as a prototype.
        let mut prototype = self.local_address.into();

        // Change the port to the newly allocated one.
        prototype.set_port(port);

        prototype
    }
}

/// Represents an allocation of a client.
struct Allocation {
    #[allow(dead_code)]
    address: SocketAddr,
}

/// Computes the effective lifetime of an allocation.
fn compute_effective_lifetime(requested_lifetime: Option<&Lifetime>) -> Lifetime {
    let Some(requested) = requested_lifetime else {
        return Lifetime::new(DEFAULT_ALLOCATION_LIFETIME).unwrap();
    };

    let effective_lifetime = requested.lifetime().min(MAX_ALLOCATION_LIFETIME);

    Lifetime::new(effective_lifetime).unwrap()
}

fn allocate_error(transaction_id: TransactionId, error_code: ErrorCode) -> Message<Attribute> {
    let mut message = Message::new(MessageClass::ErrorResponse, ALLOCATE, transaction_id);
    message.add_attribute(error_code.into());

    message
}

// Define an enum of all attributes that we care about for our server.
stun_codec::define_attribute_enums!(
    Attribute,
    AttributeDecoder,
    AttributeEncoder,
    [
        MessageIntegrity,
        XorMappedAddress,
        ErrorCode,
        RequestedTransport,
        XorRelayAddress,
        Lifetime
    ]
);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requested_lifetime_is_capped_at_max_lifetime() {
        let requested_lifetime = Lifetime::new(Duration::from_secs(10_000_000)).unwrap();

        let effective_lifetime = compute_effective_lifetime(Some(&requested_lifetime));

        assert_eq!(effective_lifetime.lifetime(), MAX_ALLOCATION_LIFETIME)
    }
}
