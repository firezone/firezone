use anyhow::Result;
use bytecodec::{DecodeExt, EncodeExt};
use rand::Rng;
use std::collections::{HashMap, HashSet, VecDeque};
use std::hash::Hash;
use std::net::{SocketAddr, SocketAddrV4, SocketAddrV6};
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
pub struct Server {
    decoder: MessageDecoder<Attribute>,
    encoder: MessageEncoder<Attribute>,

    local_ip4_address: SocketAddrV4,
    local_ip6_address: SocketAddrV6,

    /// All client allocations, indexed by client's socket address.
    allocations: HashMap<SocketAddr, Allocation>,

    used_ports: HashSet<u16>,
    pending_commands: VecDeque<Command>,
    next_allocation_id: AllocationId,
}

/// The commands returned from a [`Server`].
///
/// The [`Server`] itself is sans-IO, meaning it is the caller responsibility to cause the side-effects described by these commands.
pub enum Command {
    SendMessage {
        payload: Vec<u8>,
        recipient: SocketAddr,
    },
    /// Reserve the given port for the given duration.
    ///
    /// Any incoming data should be handed to the [`Server`] via [`Server::handle_relay_input`].
    /// The caller MUST deallocate the port after the given duration unless it is refreshed.
    AllocateAddresses {
        id: AllocationId,
        ip4: SocketAddrV4,
        ip6: SocketAddrV6,
        expiry_in: Duration,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AllocationId(u64);

impl AllocationId {
    fn next(&mut self) -> Self {
        let id = self.0;

        self.0 += 1;

        AllocationId(id)
    }
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

impl Server {
    pub fn new(local_ip4_address: SocketAddrV4, local_ip6_address: SocketAddrV6) -> Self {
        Self {
            decoder: Default::default(),
            encoder: Default::default(),
            local_ip4_address,
            local_ip6_address,
            allocations: Default::default(),
            used_ports: Default::default(),
            pending_commands: Default::default(),
            next_allocation_id: AllocationId(1),
        }
    }

    /// Process the bytes received from a client and optionally return bytes to send back to the same or a different node.
    ///
    /// After calling this method, you should call [`next_event`] until it returns `None`.
    pub fn handle_client_input(&mut self, bytes: &[u8], sender: SocketAddr) -> Result<()> {
        let Ok(message) = self.decoder.decode_from_bytes(bytes)? else {
            tracing::trace!("received broken STUN message from {sender}");
            return Ok(());
        };

        tracing::trace!("Received message {message:?} from {sender}");

        self.handle_message(message, sender);

        Ok(())
    }

    /// Process the bytes received from an allocation.
    #[allow(dead_code)]
    pub fn handle_relay_input(
        &mut self,
        _bytes: &[u8],
        _sender: SocketAddr,
        _allocation_id: AllocationId,
    ) -> Result<()> {
        // TODO: Implement

        Ok(())
    }

    /// Return the next command to be processed.
    pub fn next_command(&mut self) -> Option<Command> {
        self.pending_commands.pop_front()
    }

    fn handle_message(&mut self, message: Message<Attribute>, sender: SocketAddr) {
        if message.class() == MessageClass::Request && message.method() == BINDING {
            tracing::debug!("Received STUN binding request from: {sender}");

            self.handle_binding_request(message, sender);
            return;
        }

        if message.class() == MessageClass::Request && message.method() == ALLOCATE {
            tracing::debug!("Received TURN allocate request from: {sender}");

            let transaction_id = message.transaction_id();

            if let Err(e) = self.handle_allocate_request(message, sender) {
                self.send_message(allocate_error_response(transaction_id, e), sender);
            }

            return;
        }

        tracing::debug!(
            "Unhandled message of type {:?} and method {:?} from {}",
            message.class(),
            message.method(),
            sender
        );
    }

    fn handle_binding_request(&mut self, message: Message<Attribute>, sender: SocketAddr) {
        let mut message = Message::new(
            MessageClass::SuccessResponse,
            BINDING,
            message.transaction_id(),
        );
        message.add_attribute(XorMappedAddress::new(sender).into());

        self.send_message(message, sender);
    }

    /// Handle a TURN allocate request.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-receiving-an-allocate-reque> for details.
    fn handle_allocate_request(
        &mut self,
        message: Message<Attribute>,
        sender: SocketAddr,
    ) -> Result<(), ErrorCode> {
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

        let allocation = self.create_new_allocation();

        let mut message = Message::new(
            MessageClass::SuccessResponse,
            ALLOCATE,
            message.transaction_id(),
        );

        message.add_attribute(XorRelayAddress::new(allocation.ip4_relay_address.into()).into());
        message.add_attribute(XorRelayAddress::new(allocation.ip6_relay_address.into()).into());
        message.add_attribute(XorMappedAddress::new(sender).into());
        message.add_attribute(effective_lifetime.clone().into());

        self.pending_commands.push_back(Command::AllocateAddresses {
            id: allocation.id,
            ip4: allocation.ip4_relay_address,
            ip6: allocation.ip6_relay_address,
            expiry_in: effective_lifetime.lifetime(),
        });
        self.send_message(message, sender);

        tracing::info!(
            "Created new allocation for {sender} with address {} and lifetime {}s",
            allocation.ip4_relay_address,
            effective_lifetime.lifetime().as_secs()
        );
        tracing::info!(
            "Created new allocation for {sender} with address {} and lifetime {}s",
            allocation.ip6_relay_address,
            effective_lifetime.lifetime().as_secs()
        );

        self.allocations.insert(sender, allocation);

        Ok(())
    }

    fn create_new_allocation(&mut self) -> Allocation {
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
        let ip4_relay_address = SocketAddrV4::new(*self.local_ip4_address.ip(), port);
        let ip6_relay_address = SocketAddrV6::new(
            *self.local_ip6_address.ip(),
            port,
            self.local_ip6_address.flowinfo(),
            self.local_ip6_address.scope_id(),
        );

        // Third, grab a new allocation ID.
        let id = self.next_allocation_id.next();

        Allocation {
            id,
            ip4_relay_address,
            ip6_relay_address,
        }
    }

    fn send_message(&mut self, message: Message<Attribute>, recipient: SocketAddr) {
        let Ok(bytes) = self.encoder.encode_into_bytes(message) else {
            debug_assert!(false, "Encoding should never fail");
            return;
        };

        self.pending_commands.push_back(Command::SendMessage {
            payload: bytes,
            recipient,
        });
    }
}

/// Represents an allocation of a client.
///
/// Data arriving on any of the relay addresses will be forwarded to the client iff there is an active data channel.
struct Allocation {
    id: AllocationId,
    /// The IPv4 relay address of this allocation.
    ip4_relay_address: SocketAddrV4,
    /// The IPv6 relay address of this allocation.
    ip6_relay_address: SocketAddrV6,
}

/// Computes the effective lifetime of an allocation.
fn compute_effective_lifetime(requested_lifetime: Option<&Lifetime>) -> Lifetime {
    let Some(requested) = requested_lifetime else {
        return Lifetime::new(DEFAULT_ALLOCATION_LIFETIME).unwrap();
    };

    let effective_lifetime = requested.lifetime().min(MAX_ALLOCATION_LIFETIME);

    Lifetime::new(effective_lifetime).unwrap()
}

fn allocate_error_response(
    transaction_id: TransactionId,
    error_code: ErrorCode,
) -> Message<Attribute> {
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
