use bytecodec::{DecodeExt, EncodeExt};
use hex_literal::hex;
use relay::{AllocationId, Attribute, Command, Server};
use std::collections::HashMap;
use std::time::{Duration, Instant};
use stun_codec::rfc5389::attributes::{MessageIntegrity, Realm, Username};
use stun_codec::rfc5766::attributes::Lifetime;
use stun_codec::rfc5766::methods::REFRESH;
use stun_codec::{
    DecodedMessage, Message, MessageClass, MessageDecoder, MessageEncoder, TransactionId,
};

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
fn deallocate_once_time_expired() {
    let now = Instant::now();

    run_regression_test(&[(
        Input::client("91.141.70.157:7112", "000300482112a442998bcae2a73b55941682cf470019000411000000000600047465737400140008666972657a6f6e6500150006666f6f626172000000080014b279018b143b1c6ac194a2848d0e37958731a2f38028000497076a00", now),
        &[
            Output::Wake(now + Duration::from_secs(600)),
            Output::CreateAllocation(49152),
            Output::send_message("91.141.70.157:7112", "010300202112a442998bcae2a73b55941682cf47001600080001e112026eff670020000800013ada7a9fe2df000d000400000258"),
        ],
    ), (
        Input::Time(now + Duration::from_secs(601)),
        &[
            Output::ExpireAllocation(49152)
        ],
    )]);
}

#[test]
fn when_refreshed_in_time_allocation_does_not_expire() {
    let now = Instant::now();
    let refreshed_at = now + Duration::from_secs(300);
    let first_expiry = now + Duration::from_secs(600);

    run_regression_test(&[(
        Input::client("91.141.70.157:7112", "000300482112a442998bcae2a73b55941682cf470019000411000000000600047465737400140008666972657a6f6e6500150006666f6f626172000000080014b279018b143b1c6ac194a2848d0e37958731a2f38028000497076a00", now),
        &[
            Output::Wake(first_expiry),
            Output::CreateAllocation(49152),
            Output::send_message("91.141.70.157:7112", "010300202112a442998bcae2a73b55941682cf47001600080001e112026eff670020000800013ada7a9fe2df000d000400000258"),
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
    let now = Instant::now();
    let refreshed_at = now + Duration::from_secs(300);
    let first_expiry = now + Duration::from_secs(600);

    run_regression_test(&[(
        Input::client("91.141.70.157:7112", "000300482112a442998bcae2a73b55941682cf470019000411000000000600047465737400140008666972657a6f6e6500150006666f6f626172000000080014b279018b143b1c6ac194a2848d0e37958731a2f38028000497076a00", now),
        &[
            Output::Wake(first_expiry),
            Output::CreateAllocation(49152),
            Output::send_message("91.141.70.157:7112", "010300202112a442998bcae2a73b55941682cf47001600080001e112026eff670020000800013ada7a9fe2df000d000400000258"),
        ],
    ),(
        Input::client("91.141.70.157:7112", refresh_request(hex!("150ee0cb117ed3a0f66529f2"), 0), refreshed_at),
        &[
            Output::ExpireAllocation(49152),
            Output::send_message("91.141.70.157:7112", "010400082112a442150ee0cb117ed3a0f66529f2000d000400000000"),
        ],
    ),(
        Input::Time(first_expiry + Duration::from_secs(1)),
        &[],
    )]);
}

#[test]
fn server_waits_for_5_minutes_before_allowing_reuse_of_channel_number_after_expiry() {
    // todo!()
}

#[test]
fn ping_pong_relay() {
    let now = Instant::now();
    run_regression_test(&[(
        Input::client("127.0.0.1:42677","000300102112a44216e1c61ab424700638d1cdc70019000411000000802800040eac7235", now),
        &[
            Output::send_message("127.0.0.1:42677","0113002c2112a44216e1c61ab424700638d1cdc70009001000000401556e617574686f72697a656400150006666f6f626172000000140008666972657a6f6e65"),
        ]),
        (
        Input::client("127.0.0.1:54098","000100002112a442f0453a3bb8edcdeb333ccbe0", now),
        &[
            Output::send_message("127.0.0.1:54098","0101000c2112a442f0453a3bb8edcdeb333ccbe0002000080001f2405e12a443")],
        ),
        (
        Input::client("127.0.0.1:42677","000300482112a442998bcae2a73b55941682cf470019000411000000000600047465737400140008666972657a6f6e6500150006666f6f626172000000080014b279018b143b1c6ac194a2848d0e37958731a2f38028000497076a00", now),
        &[
            Output::Wake(now + Duration::from_secs(600)),
            Output::CreateAllocation(49152),
            Output::send_message("127.0.0.1:42677","010300202112a442998bcae2a73b55941682cf47001600080001e112026eff6700200008000187a75e12a443000d000400000258")
        ]),
        (
        Input::client("127.0.0.1:42677","0008004c2112a442dc5c115f6b727e25a54b55d3001200080001f2405e12a443000600047465737400140008666972657a6f6e6500150006666f6f626172000000080014384805e715f38de3b7b16df6dc3af51568cb073b80280004ecdfbc3d", now),
        &[
            Output::send_message("127.0.0.1:42677","010800002112a442dc5c115f6b727e25a54b55d3")
        ]),
        (
        Input::client("127.0.0.1:42677","000900542112a4420afbde5aaacfc1e9316beae9001200080001f2405e12a443000c000440000000000600047465737400140008666972657a6f6e6500150006666f6f626172000000080014aca01c6cdc1fc5339a309e5bccac3df5c903e33e802800041fe4b79b", now),
        &[
            Output::send_message("127.0.0.1:42677","010900002112a4420afbde5aaacfc1e9316beae9")
        ]),
        (
        Input::peer("127.0.0.1:54098","4a67cc90afc6a3d9dc2867fab4c5867de5adae6b8a45c710998c800067c0e1b3", 49152),
         &[
            Output::send_message("127.0.0.1:42677","400000204a67cc90afc6a3d9dc2867fab4c5867de5adae6b8a45c710998c800067c0e1b3")
        ]),
        (
         Input::client("127.0.0.1:42677","400000204a67cc90afc6a3d9dc2867fab4c5867de5adae6b8a45c710998c800067c0e1b3", now),
         &[
             Output::forward("127.0.0.1:54098","4a67cc90afc6a3d9dc2867fab4c5867de5adae6b8a45c710998c800067c0e1b3", 49152)
         ]
    )]);
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

                server.handle_client_input(&input, from, *now);
            }
            Input::Time(now) => {
                server.handle_deadline_reached(*now);
            }
            Input::Peer(from, data, port) => {
                let input = hex::decode(data).unwrap();
                let from = from.parse().unwrap();

                server.handle_relay_input(&input, from, allocation_mapping[port]);
            }
        }

        for expected_output in *output {
            let Some(actual_output) = server.next_command() else {
                let msg = match expected_output {
                    Output::SendMessage((recipient, bytes)) => format!("to send message {:?} to {recipient}", parse_hex_message(bytes)),
                    Output::Forward((ip, data, port)) => format!("forward '{data}' to {ip} on port {port}"),
                    Output::Wake(instant) => format!("to be woken at {instant:?}"),
                    Output::CreateAllocation(port) => format!("to create allocation on port {port}"),
                    Output::ExpireAllocation(port) => format!("to free allocation on port {port}"),
                };

                panic!("No commands produced but expected {msg}");
            };

            match (expected_output, actual_output) {
                (Output::SendMessage((to, bytes)), Command::SendMessage { payload, recipient }) => {
                    let expected_bytes = hex::decode(bytes).unwrap();

                    if expected_bytes != payload {
                        let expected_message =
                            format!("{:?}", parse_message(expected_bytes.as_ref()));
                        let actual_message = format!("{:?}", parse_message(payload.as_ref()));

                        difference::assert_diff!(&expected_message, &actual_message, "\n", 0);
                    }

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
                (
                    Output::Forward((to, bytes, port)),
                    Command::ForwardData { id, data, receiver },
                ) => {
                    assert_eq!(*bytes, hex::encode(data));
                    assert_eq!(receiver, to.parse().unwrap());
                    assert_eq!(allocation_mapping[port], id);
                }
                (expected, actual) => panic!("Expected: {expected:?}\nActual:   {actual:?}\n"),
            }
        }

        assert!(server.next_command().is_none())
    }
}

fn refresh_request(transaction_id: [u8; 12], lifetime: u32) -> String {
    let username = Username::new("test".to_owned()).unwrap();
    let realm = Realm::new("firezone".to_owned()).unwrap();

    let mut message = Message::<Attribute>::new(
        MessageClass::Request,
        REFRESH,
        TransactionId::new(transaction_id),
    );
    message.add_attribute(Lifetime::from_u32(lifetime).into());
    message.add_attribute(username.clone().into());
    message.add_attribute(realm.clone().into());
    let message_integrity =
        MessageIntegrity::new_long_term_credential(&message, &username, &realm, "foobar").unwrap();
    message.add_attribute(message_integrity.into());

    message_to_hex(message)
}

fn message_to_hex<A>(message: Message<A>) -> String
where
    A: stun_codec::Attribute,
{
    hex::encode(MessageEncoder::new().encode_into_bytes(message).unwrap())
}

fn parse_hex_message(message: &str) -> DecodedMessage<Attribute> {
    let message = hex::decode(message).unwrap();
    MessageDecoder::new().decode_from_bytes(&message).unwrap()
}

fn parse_message(message: &[u8]) -> DecodedMessage<Attribute> {
    MessageDecoder::new().decode_from_bytes(message).unwrap()
}

enum Input {
    Client(Ip, Bytes, Instant),
    Peer(Ip, Bytes, u16),
    Time(Instant),
}

impl Input {
    fn client(from: Ip, data: impl AsRef<str>, now: Instant) -> Self {
        Self::Client(from, data.as_ref().to_owned(), now)
    }
    fn peer(from: Ip, data: impl AsRef<str>, allocation: u16) -> Self {
        Self::Peer(from, data.as_ref().to_owned(), allocation)
    }
}

#[derive(Debug)]
enum Output {
    SendMessage((Ip, Bytes)),
    Forward((Ip, Bytes, u16)),
    Wake(Instant),
    CreateAllocation(u16),
    ExpireAllocation(u16),
}

impl Output {
    fn send_message(from: Ip, data: impl AsRef<str>) -> Self {
        Self::SendMessage((from, data.as_ref().to_owned()))
    }

    fn forward(to: Ip, data: impl AsRef<str>, port: u16) -> Self {
        Self::Forward((to, data.as_ref().to_owned(), port))
    }
}

type Ip = &'static str;
type Bytes = String;
