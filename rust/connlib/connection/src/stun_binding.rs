use crate::pool::Transmit;
use bytecodec::{DecodeExt, EncodeExt};
use std::{
    collections::VecDeque,
    net::SocketAddr,
    time::{Duration, Instant},
};
use str0m::{net::Protocol, Candidate};
use stun_codec::{
    rfc5389::{self, attributes::XorMappedAddress},
    Attribute, Message, TransactionId,
};

const STUN_TIMEOUT: Duration = Duration::from_secs(5);
const STUN_REFRESH: Duration = Duration::from_secs(5 * 60);

/// A SANS-IO state machine that obtains a server-reflexive candidate from the configured STUN server.
#[derive(Debug)]
pub struct StunBinding {
    server: SocketAddr,
    last_candidate: Option<Candidate>,
    state: State,
    last_now: Option<Instant>,

    buffered_transmits: VecDeque<Transmit<'static>>,
    new_candidates: VecDeque<Candidate>,
}

impl StunBinding {
    pub fn new(server: SocketAddr) -> Self {
        Self {
            server,
            last_candidate: None,
            state: State::Initial,
            last_now: None,
            buffered_transmits: Default::default(),
            new_candidates: Default::default(),
        }
    }

    pub fn candidate(&self) -> Option<Candidate> {
        self.last_candidate.clone()
    }

    pub fn handle_input(&mut self, from: SocketAddr, packet: &[u8], now: Instant) -> bool {
        self.last_now = Some(now); // TODO: Do we need to do any other updates here?

        if from != self.server {
            return false;
        }

        let Ok(Ok(message)) =
            stun_codec::MessageDecoder::<stun_codec::rfc5389::Attribute>::default()
                .decode_from_bytes(packet)
        else {
            return false;
        };

        match self.state {
            State::SentRequest { id, .. } if id == message.transaction_id() => {
                self.state = State::ReceivedResponse { at: now }
            }
            _ => {
                return false;
            }
        }

        let Some(mapped_address) = message.get_attribute::<XorMappedAddress>() else {
            tracing::warn!("STUN server replied but is missing `XOR-MAPPED-ADDRESS");
            return true;
        };

        let observed_address = mapped_address.address();

        let new_candidate = match Candidate::server_reflexive(observed_address, Protocol::Udp) {
            Ok(c) => c,
            Err(e) => {
                tracing::debug!("Observed address is not a valid candidate: {e}");
                return true; // We still handled the packet correctly.
            }
        };

        match &self.last_candidate {
            Some(candidate) if candidate != &new_candidate => {
                tracing::info!(current = %candidate, new = %new_candidate, "Updating server-reflexive candidate");
            }
            None => {
                tracing::info!(new = %new_candidate, "New server-reflexive candidate");
            }
            _ => return true,
        }

        self.last_candidate = Some(new_candidate.clone());
        self.new_candidates.push_back(new_candidate);

        true
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.last_now = Some(now);

        match self.state {
            State::Initial => {
                tracing::debug!(server = %self.server, "Sending new STUN request");
            }
            State::SentRequest { id, at } if at + STUN_TIMEOUT <= now => {
                tracing::debug!(?id, "STUN request timed out, sending new one");
            }
            State::ReceivedResponse { at } if at + STUN_REFRESH <= now => {
                tracing::debug!("Refreshing STUN binding");
            }
            _ => return,
        }

        let request = new_stun_request();

        self.state = State::SentRequest {
            id: request.transaction_id(),
            at: now,
        };

        self.buffered_transmits.push_back(Transmit {
            dst: self.server,
            payload: encode(request).into(),
        });
    }

    pub fn poll_candidate(&mut self) -> Option<Candidate> {
        self.new_candidates.pop_front()
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        match self.state {
            State::Initial => None,
            State::SentRequest { at, .. } => Some(at + STUN_TIMEOUT),
            State::ReceivedResponse { at } => Some(at + STUN_REFRESH),
        }
    }

    pub fn poll_transmit(&mut self) -> Option<Transmit<'static>> {
        self.buffered_transmits.pop_front()
    }

    #[cfg(test)]
    fn set_received_at(&mut self, address: SocketAddr, now: Instant) {
        self.last_now = Some(now);
        self.last_candidate = Some(Candidate::server_reflexive(address, Protocol::Udp).unwrap());
        self.state = State::ReceivedResponse { at: now };
    }
}

fn new_stun_request() -> Message<rfc5389::Attribute> {
    Message::new(
        stun_codec::MessageClass::Request,
        rfc5389::methods::BINDING,
        TransactionId::new(rand::random()),
    )
}

fn encode<A>(message: Message<A>) -> Vec<u8>
where
    A: Attribute,
{
    stun_codec::MessageEncoder::<A>::default()
        .encode_into_bytes(message)
        .unwrap()
}

#[derive(Debug)]
enum State {
    Initial,
    SentRequest { id: TransactionId, at: Instant },
    ReceivedResponse { at: Instant },
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytecodec::DecodeExt;
    use std::{
        net::{Ipv4Addr, SocketAddrV4},
        time::Duration,
    };
    use stun_codec::{
        rfc5389::{attributes::XorMappedAddress, methods::BINDING},
        Message,
    };

    const SERVER1: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 3478));
    const SERVER2: SocketAddr =
        SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(192, 168, 0, 1), 3478));
    const MAPPED_ADDRESS: SocketAddr =
        SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 1), 9999));

    #[test]
    fn initial_binding_sends_request() {
        let mut stun_binding = StunBinding::new(SERVER1);

        stun_binding.handle_timeout(Instant::now());
        let transmit = stun_binding.poll_transmit().unwrap();

        assert_eq!(transmit.dst, SERVER1);
    }

    #[test]
    fn repeated_polling_does_not_generate_more_requests() {
        let mut stun_binding = StunBinding::new(SERVER1);

        stun_binding.handle_timeout(Instant::now());

        assert!(stun_binding.poll_transmit().is_some());
        assert!(stun_binding.poll_transmit().is_none());
    }

    #[test]
    fn request_times_out_after_5_seconds_and_generates_new_request() {
        let mut stun_binding = StunBinding::new(SERVER1);

        let start = Instant::now();
        stun_binding.handle_timeout(start);

        assert!(stun_binding.poll_transmit().is_some());
        assert!(stun_binding.poll_transmit().is_none());

        assert_eq!(
            stun_binding.poll_timeout().unwrap(),
            start + Duration::from_secs(5)
        );

        // Nothing after 1 second ..
        stun_binding.handle_timeout(start + Duration::from_secs(1));
        assert!(stun_binding.poll_transmit().is_none());

        // Nothing after 2 seconds ..
        stun_binding.handle_timeout(start + Duration::from_secs(2));
        assert!(stun_binding.poll_transmit().is_none());

        stun_binding.handle_timeout(start + Duration::from_secs(5));
        assert!(stun_binding.poll_transmit().is_some());
        assert!(stun_binding.poll_transmit().is_none());
    }

    #[test]
    fn mapped_address_is_emitted_as_event() {
        let mut stun_binding = StunBinding::new(SERVER1);
        let start = Instant::now();

        stun_binding.handle_timeout(start);

        let request = stun_binding.poll_transmit().unwrap();
        let response = generate_stun_response(request, MAPPED_ADDRESS);

        let handled =
            stun_binding.handle_input(SERVER1, &response, start + Duration::from_millis(200));
        assert!(handled);

        let candidate = stun_binding.poll_candidate().unwrap();

        assert_eq!(candidate.addr(), MAPPED_ADDRESS);
    }

    #[test]
    fn stun_binding_is_refreshed_every_five_minutes() {
        let start = Instant::now();

        let mut stun_binding = StunBinding::new(SERVER1);
        stun_binding.set_received_at(MAPPED_ADDRESS, start);
        assert!(stun_binding.poll_transmit().is_none());

        stun_binding.handle_timeout(start + Duration::from_secs(5 * 60));

        assert!(stun_binding.poll_transmit().is_some());
    }

    #[test]
    fn response_from_other_server_is_discarded() {
        let mut stun_binding = StunBinding::new(SERVER1);
        let start = Instant::now();

        stun_binding.handle_timeout(start);

        let request = stun_binding.poll_transmit().unwrap();
        let response = generate_stun_response(request, MAPPED_ADDRESS);

        let handled =
            stun_binding.handle_input(SERVER2, &response, start + Duration::from_millis(200));

        assert!(!handled);
        assert!(stun_binding.poll_candidate().is_none());
    }

    fn generate_stun_response(request: Transmit, mapped_address: SocketAddr) -> Vec<u8> {
        let mut decoder = stun_codec::MessageDecoder::<stun_codec::rfc5389::Attribute>::default();

        let message = decoder
            .decode_from_bytes(&request.payload)
            .unwrap()
            .unwrap();

        let transaction_id = message.transaction_id();

        let mut response = Message::<rfc5389::Attribute>::new(
            stun_codec::MessageClass::SuccessResponse,
            BINDING,
            transaction_id,
        );
        response.add_attribute(stun_codec::rfc5389::Attribute::XorMappedAddress(
            XorMappedAddress::new(mapped_address),
        ));

        encode(response)
    }
}
