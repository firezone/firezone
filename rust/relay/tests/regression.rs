use bytecodec::EncodeExt;
use hex_literal::hex;
use relay::{AllocationId, Command, Server};
use std::collections::HashMap;
use std::time::{Duration, Instant};
use stun_codec::rfc5766::attributes::Lifetime;
use stun_codec::rfc5766::methods::REFRESH;
use stun_codec::{Attribute, Message, MessageClass, MessageEncoder, TransactionId};

#[test]
fn stun_binding_request() {
    run_regression_test(&[(
        Input::client(
            "91.141.64.64:26098",
            "000100002112a4420908af7d45e8751f5092d167",
            Instant::now(),
        ),
        &[Output::send_message(
            "91.141.64.64:26098",
            "0101000c2112a4420908af7d45e8751f5092d16700200008000144e07a9fe402",
        )],
    )]);
}

#[test]
fn turn_allocation_request() {
    let now = Instant::now();

    run_regression_test(&[(
        Input::client("91.141.70.157:7112", "000300182112a44215d4bb014ad31072cd248ec70019000411000000000d000400000e1080280004d08a7674", now),
        &[
            Output::Wake(now + Duration::from_secs(3600)),
            Output::CreateAllocation(49152),
            Output::send_message("91.141.70.157:7112", "010300202112a44215d4bb014ad31072cd248ec7001600080001e112026eff670020000800013ada7a9fe2df000d000400000e10"),
        ],
    )]);
}

#[test]
fn deallocate_once_time_expired() {
    let now = Instant::now();

    run_regression_test(&[(
        Input::client("91.141.70.157:7112", "000300182112a44215d4bb014ad31072cd248ec70019000411000000000d000400000e1080280004d08a7674", now),
        &[
            Output::Wake(now + Duration::from_secs(3600)),
            Output::CreateAllocation(49152),
            Output::send_message("91.141.70.157:7112", "010300202112a44215d4bb014ad31072cd248ec7001600080001e112026eff670020000800013ada7a9fe2df000d000400000e10"),
        ],
    ), (
        Input::Time(now + Duration::from_secs(3601)),
        &[
            Output::ExpireAllocation(49152)
        ],
    )]);
}

#[test]
fn when_refreshed_in_time_allocation_does_not_expire() {
    let now = Instant::now();
    let refreshed_at = now + Duration::from_secs(1800);
    let first_expiry = now + Duration::from_secs(3600);

    run_regression_test(&[(
        Input::client("91.141.70.157:7112", "000300182112a44215d4bb014ad31072cd248ec70019000411000000000d000400000e1080280004d08a7674", now),
        &[
            Output::Wake(first_expiry),
            Output::CreateAllocation(49152),
            Output::send_message("91.141.70.157:7112", "010300202112a44215d4bb014ad31072cd248ec7001600080001e112026eff670020000800013ada7a9fe2df000d000400000e10"),
        ],
    ),(
        Input::client("91.141.70.157:7112", refresh_request(hex!("150ee0cb117ed3a0f66529f2"), 3600), refreshed_at),
        &[
            Output::Wake(first_expiry), // `first_expiry` would still happen after the refresh but it will be a no-op wake-up.
            Output::send_message("91.141.70.157:7112", "010400082112a442150ee0cb117ed3a0f66529f2000d000400000e10"),
        ],
    ),(
        Input::Time(first_expiry + Duration::from_secs(1)),
        &[],
    )]);
}

#[test]
fn when_receiving_lifetime_0_for_existing_allocation_then_delete() {
    todo!()
}

/// Run a regression test with a sequence events where we always have 1 input and N outputs.
fn run_regression_test(sequence: &[(Input, &[Output])]) {
    let _ = env_logger::try_init();

    let mut server = Server::test();

    let mut allocation_mapping = HashMap::<u16, AllocationId>::default();

    for (input, output) in sequence {
        match input {
            Input::Client(from, data, now) => {
                let input = hex::decode(data).unwrap();
                let from = from.parse().unwrap();

                server.handle_client_input(&input, from, *now).unwrap();
            }
            Input::Time(now) => {
                server.handle_deadline_reached(*now);
            }
        }

        for expected_output in *output {
            let actual_output = server
                .next_command()
                .unwrap_or_else(|| panic!("no commands produced but expected {expected_output:?}"));

            match (expected_output, actual_output) {
                (Output::SendMessage((to, bytes)), Command::SendMessage { payload, recipient }) => {
                    assert_eq!(*bytes, hex::encode(payload));
                    assert_eq!(recipient, to.parse().unwrap());
                }
                (
                    Output::CreateAllocation(expected_port),
                    Command::AllocateAddresses { port, id },
                ) => {
                    assert_eq!(port, *expected_port);

                    allocation_mapping.insert(*expected_port, id);
                }
                (Output::Wake(expected), Command::Wake { deadline }) => {
                    assert_eq!(*expected, deadline);
                }
                (Output::ExpireAllocation(port), Command::FreeAddresses { id }) => {
                    let expected_id = allocation_mapping.remove(port).expect("unknown allocation");

                    assert_eq!(expected_id, id);
                }
                (expected, actual) => panic!("Expected: {expected:?}\nActual:   {actual:?}\n"),
            }
        }

        assert!(server.next_command().is_none())
    }
}

fn refresh_request(transaction_id: [u8; 12], lifetime: u32) -> String {
    let mut message = Message::new(
        MessageClass::Request,
        REFRESH,
        TransactionId::new(transaction_id),
    );
    message.add_attribute(Lifetime::from_u32(lifetime));

    message_to_hex(message)
}

fn message_to_hex<A>(message: Message<A>) -> String
where
    A: Attribute,
{
    hex::encode(MessageEncoder::new().encode_into_bytes(message).unwrap())
}

enum Input {
    Client(Ip, Bytes, Instant),
    Time(Instant),
}

impl Input {
    fn client(from: Ip, data: impl AsRef<str>, now: Instant) -> Self {
        Self::Client(from, data.as_ref().to_owned(), now)
    }
}

#[derive(Debug)]
enum Output {
    SendMessage((Ip, Bytes)),
    Wake(Instant),
    CreateAllocation(u16),
    ExpireAllocation(u16),
}

impl Output {
    fn send_message(from: Ip, data: impl AsRef<str>) -> Self {
        Self::SendMessage((from, data.as_ref().to_owned()))
    }
}

type Ip = &'static str;
type Bytes = String;
