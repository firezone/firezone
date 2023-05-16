use crate::TimeEvents;
use anyhow::Result;
use bytecodec::{DecodeExt, EncodeExt};
use core::fmt;
use rand::rngs::mock::StepRng;
use rand::rngs::ThreadRng;
use rand::Rng;
use std::collections::{HashMap, VecDeque};
use std::hash::Hash;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::time::{Duration, Instant};
use stun_codec::rfc5389::attributes::{ErrorCode, MessageIntegrity, XorMappedAddress};
use stun_codec::rfc5389::errors::BadRequest;
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::attributes::{Lifetime, RequestedTransport, XorRelayAddress};
use stun_codec::rfc5766::errors::{AllocationMismatch, InsufficientCapacity};
use stun_codec::rfc5766::methods::{ALLOCATE, REFRESH};
use stun_codec::{Message, MessageClass, MessageDecoder, MessageEncoder, Method, TransactionId};

/// A sans-IO STUN & TURN server.
///
/// A [`Server`] is bound to an IPv4 address and assumes to only operate on UDP.
/// Thus, 3 out of the 5 components of a "5-tuple" are unique to an instance of [`Server`] and
/// we can index data simply by the sender's [`SocketAddr`].
///
/// Additionally, we assume to have complete ownership over the port range `LOWEST_PORT` - `HIGHEST_PORT`.
pub struct Server<R = ThreadRng> {
    decoder: MessageDecoder<Attribute>,
    encoder: MessageEncoder<Attribute>,

    public_ip4_address: SocketAddrV4,

    /// All client allocations, indexed by client's socket address.
    allocations: HashMap<SocketAddr, Allocation>,

    clients_by_allocation: HashMap<AllocationId, SocketAddr>,
    allocations_by_port: HashMap<u16, AllocationId>,

    pending_commands: VecDeque<Command>,
    next_allocation_id: AllocationId,

    rng: R,

    time_events: TimeEvents<TimedAction>,
}

/// The commands returned from a [`Server`].
///
/// The [`Server`] itself is sans-IO, meaning it is the caller responsibility to cause the side-effects described by these commands.
#[derive(Debug)]
pub enum Command {
    SendMessage {
        payload: Vec<u8>,
        recipient: SocketAddr,
    },
    /// Listen for traffic on the provided IP addresses.
    ///
    /// Any incoming data should be handed to the [`Server`] via [`Server::handle_relay_input`].
    AllocateAddresses { id: AllocationId, port: u16 },
    /// Free the addresses associated with the given [`AllocationId`].
    FreeAddresses { id: AllocationId },
    /// At the latest, the [`Server`] needs to be woken at the specified deadline to execute time-based actions correctly.
    Wake { deadline: Instant },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct AllocationId(u64);

impl AllocationId {
    fn next(&mut self) -> Self {
        let id = self.0;

        self.0 += 1;

        AllocationId(id)
    }
}

impl fmt::Display for AllocationId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "AID-{}", self.0)
    }
}

/// See <https://www.rfc-editor.org/rfc/rfc8656#name-requested-transport>.
const UDP_TRANSPORT: u8 = 17;

const LOWEST_PORT: u16 = 49152;
const HIGHEST_PORT: u16 = 65535;

/// The maximum number of ports available for allocation.
const MAX_AVAILABLE_PORTS: u16 = HIGHEST_PORT - LOWEST_PORT;

/// The maximum lifetime of an allocation.
const MAX_ALLOCATION_LIFETIME: Duration = Duration::from_secs(3600);

/// The default lifetime of an allocation.
///
/// See <https://www.rfc-editor.org/rfc/rfc8656#name-allocations-2>.
const DEFAULT_ALLOCATION_LIFETIME: Duration = Duration::from_secs(600);

impl Server {
    pub fn new(public_ip4_address: SocketAddrV4) -> Self {
        // TODO: Validate that local IP isn't multicast / loopback etc.

        Self {
            decoder: Default::default(),
            encoder: Default::default(),
            public_ip4_address,
            allocations: Default::default(),
            clients_by_allocation: Default::default(),
            allocations_by_port: Default::default(),
            pending_commands: Default::default(),
            next_allocation_id: AllocationId(1),
            rng: rand::thread_rng(),
            time_events: TimeEvents::default(),
        }
    }
}

impl<R> Server<R>
where
    R: Rng,
{
    /// Process the bytes received from a client.
    ///
    /// After calling this method, you should call [`Server::next_command`] until it returns `None`.
    pub fn handle_client_input(
        &mut self,
        bytes: &[u8],
        sender: SocketAddr,
        now: Instant,
    ) -> Result<()> {
        let Ok(message) = self.decoder.decode_from_bytes(bytes)? else {
            tracing::trace!("received broken STUN message from {sender}");
            return Ok(());
        };

        tracing::trace!("Received message {message:?} from {sender}");

        self.handle_message(message, sender, now);

        Ok(())
    }

    /// Process the bytes received from an allocation.
    #[allow(dead_code)]
    pub fn handle_relay_input(
        &mut self,
        _bytes: &[u8],
        _sender: SocketAddr,
        _allocation_id: AllocationId,
    ) {
        // TODO: Implement
    }

    pub fn handle_deadline_reached(&mut self, now: Instant) {
        for action in self.time_events.pending_actions(now) {
            match action {
                TimedAction::ExpireAllocation(id) => {
                    let Some(allocation) = self.get_allocation(&id) else {
                        tracing::debug!("Cannot expire non-existing allocation {id}");

                        continue;
                    };

                    if allocation.is_expired(now) {
                        self.delete_allocation(id)
                    }
                }
            }
        }
    }

    /// Return the next command to be executed.
    pub fn next_command(&mut self) -> Option<Command> {
        self.pending_commands.pop_front()
    }

    fn handle_message(&mut self, message: Message<Attribute>, sender: SocketAddr, now: Instant) {
        if message.class() == MessageClass::Request && message.method() == BINDING {
            tracing::debug!("Received STUN binding request from: {sender}");

            self.handle_binding_request(message, sender);
            return;
        }

        if message.class() == MessageClass::Request && message.method() == ALLOCATE {
            tracing::debug!("Received TURN allocate request from: {sender}");

            let transaction_id = message.transaction_id();

            if let Err(e) = self.handle_allocate_request(message, sender, now) {
                self.send_message(error_response(transaction_id, ALLOCATE, e), sender);
            }

            return;
        }

        if message.class() == MessageClass::Request && message.method() == REFRESH {
            tracing::debug!("Received TURN refresh request from: {sender}");

            let transaction_id = message.transaction_id();

            if let Err(e) = self.handle_refresh_request(message, sender, now) {
                self.send_message(error_response(transaction_id, ALLOCATE, e), sender);
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
        now: Instant,
    ) -> Result<(), ErrorCode> {
        if self.allocations.contains_key(&sender) {
            return Err(AllocationMismatch.into());
        }

        if self.allocations_by_port.len() == MAX_AVAILABLE_PORTS as usize {
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

        let allocation = self.create_new_allocation(now, &effective_lifetime);

        let mut message = Message::new(
            MessageClass::SuccessResponse,
            ALLOCATE,
            message.transaction_id(),
        );

        let ip4_relay_address = self.public_relay_address_for_port(allocation.port);

        message.add_attribute(XorRelayAddress::new(ip4_relay_address.into()).into());
        message.add_attribute(XorMappedAddress::new(sender).into());
        message.add_attribute(effective_lifetime.clone().into());

        let wake_deadline = self.time_events.add(
            allocation.expires_at,
            TimedAction::ExpireAllocation(allocation.id),
        );
        self.pending_commands.push_back(Command::Wake {
            deadline: wake_deadline,
        });
        self.pending_commands.push_back(Command::AllocateAddresses {
            id: allocation.id,
            port: allocation.port,
        });
        self.send_message(message, sender);

        tracing::info!(
            "Created new allocation for {sender} on port {} and lifetime {}s",
            allocation.port,
            effective_lifetime.lifetime().as_secs()
        );

        self.clients_by_allocation.insert(allocation.id, sender);
        self.allocations.insert(sender, allocation);

        Ok(())
    }

    /// Handle a TURN refresh request.
    ///
    /// See <https://www.rfc-editor.org/rfc/rfc8656#name-receiving-a-refresh-request> for details.
    fn handle_refresh_request(
        &mut self,
        message: Message<Attribute>,
        sender: SocketAddr,
        now: Instant,
    ) -> Result<(), ErrorCode> {
        // TODO: Verify that this is the correct error code.
        let allocation = self
            .allocations
            .get_mut(&sender)
            .ok_or(ErrorCode::from(AllocationMismatch))?;

        let requested_lifetime = message.get_attribute::<Lifetime>();
        let effective_lifetime = compute_effective_lifetime(requested_lifetime);

        if effective_lifetime.lifetime().is_zero() {
            let port = allocation.port;

            self.pending_commands
                .push_back(Command::FreeAddresses { id: allocation.id });
            self.allocations.remove(&sender);
            self.allocations_by_port.remove(&port);
            self.send_message(
                refresh_success_response(effective_lifetime, message.transaction_id()),
                sender,
            );

            tracing::info!("Deleted allocation for {sender} on port {port}");

            return Ok(());
        }

        allocation.expires_at = now + effective_lifetime.lifetime();

        tracing::info!(
            "Refreshed allocation for {sender} on port {} and lifetime {}s",
            allocation.port,
            effective_lifetime.lifetime().as_secs()
        );

        let wake_deadline = self.time_events.add(
            allocation.expires_at,
            TimedAction::ExpireAllocation(allocation.id),
        );
        self.pending_commands.push_back(Command::Wake {
            deadline: wake_deadline,
        });
        self.send_message(
            refresh_success_response(effective_lifetime, message.transaction_id()),
            sender,
        );

        Ok(())
    }

    fn create_new_allocation(&mut self, now: Instant, lifetime: &Lifetime) -> Allocation {
        // First, find an unused port.

        assert!(
            self.allocations_by_port.len() < MAX_AVAILABLE_PORTS as usize,
            "No more ports available; this would loop forever"
        );

        let port = loop {
            let candidate = self.rng.gen_range(LOWEST_PORT..HIGHEST_PORT);

            if !self.allocations_by_port.contains_key(&candidate) {
                break candidate;
            }
        };

        // Second, grab a new allocation ID.
        let id = self.next_allocation_id.next();

        self.allocations_by_port.insert(port, id);

        Allocation {
            id,
            port,
            expires_at: now + lifetime.lifetime(),
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

    fn public_relay_address_for_port(&self, port: u16) -> SocketAddrV4 {
        let ip4_relay_address = SocketAddrV4::new(*self.public_ip4_address.ip(), port);

        ip4_relay_address
    }

    fn get_allocation(&self, id: &AllocationId) -> Option<&Allocation> {
        self.clients_by_allocation
            .get(id)
            .and_then(|client| self.allocations.get(client))
    }

    fn delete_allocation(&mut self, id: AllocationId) {
        let Some(client) = self.clients_by_allocation.remove(&id) else {
            return;
        };

        self.allocations.remove(&client);
        self.pending_commands
            .push_back(Command::FreeAddresses { id });
    }
}

fn refresh_success_response(
    effective_lifetime: Lifetime,
    transaction_id: TransactionId,
) -> Message<Attribute> {
    let mut message = Message::new(MessageClass::SuccessResponse, REFRESH, transaction_id);
    message.add_attribute(effective_lifetime.into());
    message
}

impl Server<StepRng> {
    #[allow(dead_code)]
    pub fn test() -> Self {
        let local_ip4_address = Ipv4Addr::new(35, 124, 91, 37);

        Self {
            decoder: Default::default(),
            encoder: Default::default(),
            public_ip4_address: SocketAddrV4::new(local_ip4_address, 3478),
            allocations: HashMap::new(),
            clients_by_allocation: Default::default(),
            allocations_by_port: Default::default(),
            next_allocation_id: AllocationId::default(),
            pending_commands: VecDeque::new(),
            rng: StepRng::new(0, 0),
            time_events: TimeEvents::default(),
        }
    }
}

/// Represents an allocation of a client.
struct Allocation {
    id: AllocationId,
    /// Data arriving on this port will be forwarded to the client iff there is an active data channel.
    port: u16,
    expires_at: Instant,
}

impl Allocation {
    fn is_expired(&self, now: Instant) -> bool {
        self.expires_at <= now
    }
}

enum TimedAction {
    ExpireAllocation(AllocationId),
}

/// Computes the effective lifetime of an allocation.
fn compute_effective_lifetime(requested_lifetime: Option<&Lifetime>) -> Lifetime {
    let Some(requested) = requested_lifetime else {
        return Lifetime::new(DEFAULT_ALLOCATION_LIFETIME).unwrap();
    };

    let effective_lifetime = requested.lifetime().min(MAX_ALLOCATION_LIFETIME);

    Lifetime::new(effective_lifetime).unwrap()
}

fn error_response(
    transaction_id: TransactionId,
    method: Method,
    error_code: ErrorCode,
) -> Message<Attribute> {
    let mut message = Message::new(MessageClass::ErrorResponse, method, transaction_id);
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
