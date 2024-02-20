use crate::{
    backoff,
    node::{CandidateEvent, Transmit},
    ringbuffer::RingBuffer,
};
use ::backoff::backoff::Backoff;
use backoff::ExponentialBackoff;
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

const STUN_TIMEOUT: Duration = Duration::from_secs(1);
const STUN_REFRESH: Duration = Duration::from_secs(5 * 60);

/// A SANS-IO state machine that obtains a server-reflexive candidate from the configured STUN server.
#[derive(Debug)]
pub struct StunBinding {
    server: SocketAddr,
    last_candidate: Option<Candidate>,
    state: State,
    last_now: Instant,

    backoff: ExponentialBackoff,

    /// When we time out requests, we remember the last [`TransactionId`]s to be able to recognize them in case they do arrive later.
    timed_out_requests: RingBuffer<TransactionId>,

    buffered_transmits: VecDeque<Transmit<'static>>,
    events: VecDeque<CandidateEvent>,
}

impl StunBinding {
    pub fn new(server: SocketAddr, now: Instant) -> Self {
        let mut backoff = backoff::new(now, STUN_TIMEOUT);

        let (state, transmit) = new_binding_request(
            server,
            now,
            backoff.next_backoff().expect("to have an initial backoff"),
        );

        Self {
            server,
            last_candidate: None,
            state,
            last_now: now,
            buffered_transmits: VecDeque::from([transmit]),
            events: Default::default(),
            backoff,
            timed_out_requests: RingBuffer::new(100),
        }
    }

    pub fn candidate(&self) -> Option<Candidate> {
        self.last_candidate.clone()
    }

    pub fn handle_input(
        &mut self,
        from: SocketAddr,
        local: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> bool {
        self.last_now = now; // TODO: Do we need to do any other updates here?

        if from != self.server {
            return false;
        }

        let Ok(Ok(message)) =
            stun_codec::MessageDecoder::<stun_codec::rfc5389::Attribute>::default()
                .decode_from_bytes(packet)
        else {
            return false;
        };

        let transaction_id = message.transaction_id();

        if self.timed_out_requests.remove(&transaction_id) {
            tracing::debug!(
                ?transaction_id,
                "Received response to timed-out request, ignoring"
            );
            return true;
        }

        match self.state {
            State::SentRequest { id, .. } if id == transaction_id => {
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

        let new_candidate =
            match Candidate::server_reflexive(observed_address, local, Protocol::Udp) {
                Ok(c) => c,
                Err(e) => {
                    tracing::debug!("Observed address is not a valid candidate: {e}");
                    return true; // We still handled the packet correctly.
                }
            };

        match self.last_candidate.take() {
            Some(candidate) if candidate != new_candidate => {
                tracing::info!(current = %candidate, new = %new_candidate, "Updating server-reflexive candidate");
                // self.events.push_back(CandidateEvent::Expired(candidate)); TODO: Is this a good idea? Just because on STUN server says so doesn't necessarily mean the server-reflexive address is completely invalid? Not sure...
            }
            None => {
                tracing::info!(new = %new_candidate, "New server-reflexive candidate");
            }
            _ => return true,
        }

        self.last_candidate = Some(new_candidate.clone());
        self.events.push_back(CandidateEvent::New(new_candidate));

        true
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.last_now = now;
        self.backoff.clock.now = now;

        let backoff = match self.state {
            State::SentRequest { id, at, backoff } if at + backoff <= now => {
                match self.backoff.next_backoff() {
                    Some(backoff) => {
                        tracing::debug!(?id, "STUN request timed out, sending new one");

                        self.timed_out_requests.push(id);

                        backoff
                    }
                    None => {
                        tracing::info!(server = %self.server, "Giving up on attempting STUN binding");
                        self.state = State::Failed;

                        return;
                    }
                }
            }
            State::ReceivedResponse { at } if at + STUN_REFRESH <= now => {
                tracing::debug!("Refreshing STUN binding");

                self.backoff.reset(); // We have received a response previously, reset the backoff for the next request.
                self.backoff
                    .next_backoff()
                    .expect("we just reset the backoff")
            }
            _ => return,
        };

        let (state, transmit) = new_binding_request(self.server, now, backoff);
        self.state = state;
        self.buffered_transmits.push_back(transmit);
    }

    pub fn poll_event(&mut self) -> Option<CandidateEvent> {
        self.events.pop_front()
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        match self.state {
            State::SentRequest { at, backoff, .. } => Some(at + backoff),
            State::ReceivedResponse { at } => Some(at + STUN_REFRESH),
            State::Failed => None,
        }
    }

    pub fn poll_transmit(&mut self) -> Option<Transmit<'static>> {
        self.buffered_transmits.pop_front()
    }

    #[cfg(test)]
    fn set_received_at(&mut self, address: SocketAddr, local: SocketAddr, now: Instant) {
        self.last_now = now;

        self.backoff.clock.now = now;
        self.backoff.reset();

        self.last_candidate =
            Some(Candidate::server_reflexive(address, local, Protocol::Udp).unwrap());
        self.state = State::ReceivedResponse { at: now };
    }
}

fn new_binding_request(
    server: SocketAddr,
    now: Instant,
    backoff: Duration,
) -> (State, Transmit<'static>) {
    let request = Message::<rfc5389::Attribute>::new(
        stun_codec::MessageClass::Request,
        rfc5389::methods::BINDING,
        TransactionId::new(rand::random()),
    );

    let state = State::SentRequest {
        id: request.transaction_id(),
        at: now,
        backoff,
    };

    let transmit = Transmit {
        src: None,
        dst: server,
        payload: encode(request).into(),
    };

    (state, transmit)
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
    SentRequest {
        id: TransactionId,
        at: Instant,
        backoff: Duration,
    },
    ReceivedResponse {
        at: Instant,
    },
    Failed,
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
        let mut stun_binding = StunBinding::new(SERVER1, Instant::now());

        let transmit = stun_binding.poll_transmit().unwrap();

        assert_eq!(transmit.dst, SERVER1);
    }

    #[test]
    fn repeated_polling_does_not_generate_more_requests() {
        let mut stun_binding = StunBinding::new(SERVER1, Instant::now());

        assert!(stun_binding.poll_transmit().is_some());
        assert!(stun_binding.poll_transmit().is_none());
    }

    #[test]
    fn backoff_resets_after_successful_response() {
        let mut now = Instant::now();

        let mut stun_binding = StunBinding::new(SERVER1, now);

        assert!(
            stun_binding.poll_transmit().is_some(),
            "Expect initial STUN binding"
        );

        now += Duration::from_millis(500);

        stun_binding.handle_timeout(now);
        assert!(
            stun_binding.poll_transmit().is_none(),
            "Expect no retry after 500ms"
        );

        now += Duration::from_millis(500);

        stun_binding.handle_timeout(now);
        let request = stun_binding
            .poll_transmit()
            .expect("expect retry after 1 seconds");

        now += Duration::from_secs(1);

        let response = generate_stun_response(request, MAPPED_ADDRESS);
        stun_binding.handle_input(SERVER1, MAPPED_ADDRESS, &response, now);

        now += Duration::from_secs(5 * 60);

        // Refresh after 5 minutes
        assert_eq!(stun_binding.poll_timeout().unwrap(), now);
        stun_binding.handle_timeout(now);
        assert!(stun_binding.poll_transmit().is_some());

        assert_eq!(
            stun_binding.poll_timeout().unwrap(),
            now + Duration::from_secs(1),
            "backoff should be back to 1 seconds timeout"
        );
    }

    #[test]
    fn retries_requests_using_backoff_and_gives_up_eventually() {
        let start = Instant::now();
        let mut stun_binding = StunBinding::new(SERVER1, start);

        let mut expected_backoffs = VecDeque::from(backoff::steps(start));

        loop {
            let Some(timeout) = stun_binding.poll_timeout() else {
                break;
            };

            assert_eq!(expected_backoffs.pop_front().unwrap(), timeout);

            assert!(stun_binding.poll_transmit().is_some());
            assert!(stun_binding.poll_transmit().is_none());

            stun_binding.handle_timeout(timeout);
        }

        assert!(expected_backoffs.is_empty())
    }

    #[test]
    fn mapped_address_is_emitted_as_event() {
        let start = Instant::now();

        let mut stun_binding = StunBinding::new(SERVER1, start);

        let request = stun_binding.poll_transmit().unwrap();
        let response = generate_stun_response(request, MAPPED_ADDRESS);

        let handled = stun_binding.handle_input(
            SERVER1,
            MAPPED_ADDRESS,
            &response,
            start + Duration::from_millis(200),
        );
        assert!(handled);

        let event = stun_binding.poll_event().unwrap();

        assert_eq!(
            event,
            CandidateEvent::New(
                Candidate::server_reflexive(MAPPED_ADDRESS, MAPPED_ADDRESS, Protocol::Udp).unwrap()
            )
        );
    }

    #[test]
    fn stun_binding_is_refreshed_every_five_minutes() {
        let start = Instant::now();

        let mut stun_binding = StunBinding::new(SERVER1, start);
        assert!(stun_binding.poll_transmit().is_some());
        stun_binding.set_received_at(MAPPED_ADDRESS, MAPPED_ADDRESS, start);
        assert!(stun_binding.poll_transmit().is_none());

        stun_binding.handle_timeout(start + Duration::from_secs(5 * 60));

        assert!(stun_binding.poll_transmit().is_some());
    }

    #[test]
    fn response_from_other_server_is_discarded() {
        let start = Instant::now();

        let mut stun_binding = StunBinding::new(SERVER1, start);

        let request = stun_binding.poll_transmit().unwrap();
        let response = generate_stun_response(request, MAPPED_ADDRESS);

        let handled = stun_binding.handle_input(
            SERVER2,
            MAPPED_ADDRESS,
            &response,
            start + Duration::from_millis(200),
        );

        assert!(!handled);
        assert!(stun_binding.poll_event().is_none());
    }

    #[test]
    fn timed_out_response_is_still_handled() {
        let start = Instant::now();

        let mut stun_binding = StunBinding::new(SERVER1, start);

        let first_request = stun_binding.poll_transmit().unwrap();

        let timeout = stun_binding.poll_timeout().unwrap();
        stun_binding.handle_timeout(timeout);

        let _second_request = stun_binding.poll_transmit().unwrap();

        let handled = stun_binding.handle_input(
            SERVER1,
            MAPPED_ADDRESS,
            &generate_stun_response(first_request, MAPPED_ADDRESS),
            start + Duration::from_secs(5),
        );

        assert!(handled);
        assert!(stun_binding.poll_event().is_none());
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
