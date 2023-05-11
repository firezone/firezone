use crate::TimeEvents;
use anyhow::Result;
use bytecodec::{DecodeExt, EncodeExt};
use core::fmt;
use rand::rngs::mock::StepRng;
use rand::rngs::ThreadRng;
use rand::Rng;
use std::collections::{HashMap, HashSet, VecDeque};
use std::hash::Hash;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};
use std::time::{Duration, Instant};
use stun_codec::rfc5389::attributes::{ErrorCode, MessageIntegrity, XorMappedAddress};
use stun_codec::rfc5389::errors::BadRequest;
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::attributes::{Lifetime, RequestedTransport, XorRelayAddress};
use stun_codec::rfc5766::errors::{AllocationMismatch, InsufficientCapacity};
use stun_codec::rfc5766::methods::ALLOCATE;
use stun_codec::{Message, MessageClass, MessageDecoder, MessageEncoder, TransactionId};

/// A sans-IO STUN & TURN server.
///
/// A [`Server`] is bound to pair of IPv4 and IPv6 addresses and assumes to only operate on UDP.
/// Thus, 3 out of the 5 components of a "5-tuple" are unique to an instance of [`Server`] and
/// we can index data simply by the sender's [`SocketAddr`].
///
/// Additionally, we assume to have complete ownership over the port range 49152 - 65535.
pub struct Server<R = ThreadRng> {
    decoder: MessageDecoder<Attribute>,
    encoder: MessageEncoder<Attribute>,

    local_ip4_address: SocketAddrV4,
    local_ip6_address: SocketAddrV6,

    /// All client allocations, indexed by client's socket address.
    allocations: HashMap<SocketAddr, Allocation>,

    clients_by_allocation: HashMap<AllocationId, SocketAddr>,

    used_ports: HashSet<u16>,
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
        // TODO: Validate that local IPs aren't multicast / loopback etc.

        Self {
            decoder: Default::default(),
            encoder: Default::default(),
            local_ip4_address,
            local_ip6_address,
            allocations: Default::default(),
            clients_by_allocation: Default::default(),
            used_ports: Default::default(),
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
        now: Instant,
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

        let allocation = self.create_new_allocation(now, &effective_lifetime);

        let mut message = Message::new(
            MessageClass::SuccessResponse,
            ALLOCATE,
            message.transaction_id(),
        );

        let (ip4_relay_address, ip6_relay_address) =
            self.public_relay_addresses_for_port(allocation.port);

        message.add_attribute(XorRelayAddress::new(ip4_relay_address.into()).into());
        message.add_attribute(XorRelayAddress::new(ip6_relay_address.into()).into());
        message.add_attribute(XorMappedAddress::new(sender).into());
        message.add_attribute(effective_lifetime.clone().into());

        self.time_events.add(
            allocation.expires_at,
            TimedAction::ExpireAllocation(allocation.id),
        );
        let wake_deadline = self
            .time_events
            .next_trigger()
            .expect("we just pushed a time event");

        self.pending_commands.push_back(Command::Wake {
            deadline: wake_deadline,
        });
        self.pending_commands.push_back(Command::AllocateAddresses {
            id: allocation.id,
            port: allocation.port,
        });
        self.send_message(message, sender);

        tracing::info!(
            "Created new allocation for {sender} with on port {} and lifetime {}s",
            allocation.port,
            effective_lifetime.lifetime().as_secs()
        );

        self.clients_by_allocation.insert(allocation.id, sender);
        self.allocations.insert(sender, allocation);

        Ok(())
    }

    fn create_new_allocation(&mut self, now: Instant, lifetime: &Lifetime) -> Allocation {
        // First, find an unused port.

        assert!(
            self.used_ports.len() < MAX_AVAILABLE_PORTS as usize,
            "No more ports available; this would loop forever"
        );

        let port = loop {
            let candidate = self.rng.gen_range(49152..65535);

            if !self.used_ports.contains(&candidate) {
                self.used_ports.insert(candidate);
                break candidate;
            }
        };

        // Second, grab a new allocation ID.
        let id = self.next_allocation_id.next();

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

    fn public_relay_addresses_for_port(&self, port: u16) -> (SocketAddrV4, SocketAddrV6) {
        // Second, take the local address of the server as a prototype.
        let ip4_relay_address = SocketAddrV4::new(*self.local_ip4_address.ip(), port);
        let ip6_relay_address = SocketAddrV6::new(
            *self.local_ip6_address.ip(),
            port,
            self.local_ip6_address.flowinfo(),
            self.local_ip6_address.scope_id(),
        );

        (ip4_relay_address, ip6_relay_address)
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

impl Server<StepRng> {
    #[allow(dead_code)]
    pub fn test() -> Self {
        let local_ip4_address = Ipv4Addr::new(35, 124, 91, 37);
        let local_ip6_address = Ipv6Addr::new(
            0x2600, 0x1f18, 0x0f96, 0xe710, 0x2a51, 0x0e8f, 0x7303, 0x6942,
        );

        Self {
            decoder: Default::default(),
            encoder: Default::default(),
            local_ip4_address: SocketAddrV4::new(local_ip4_address, 3478),
            local_ip6_address: SocketAddrV6::new(local_ip6_address, 3478, 0, 0),
            allocations: HashMap::new(),
            clients_by_allocation: Default::default(),
            used_ports: HashSet::new(),
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
