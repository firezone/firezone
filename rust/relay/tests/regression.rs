use relay::{AllocationId, Command, Server};
use std::collections::HashMap;
use std::time::{Duration, Instant};

#[test]
fn stun_binding_request() {
    run_regression_test(&[(
        Input::Client(
            "91.141.64.64:26098",
            "000100002112a4420908af7d45e8751f5092d167",
            Instant::now(),
        ),
        &[Output::SendMessage((
            "91.141.64.64:26098",
            "0101000c2112a4420908af7d45e8751f5092d16700200008000144e07a9fe402",
        ))],
    )]);
}

#[test]
fn turn_allocation_request() {
    let now = Instant::now();

    run_regression_test(&[(
        Input::Client("91.141.70.157:7112", "000300182112a44215d4bb014ad31072cd248ec70019000411000000000d000400000e1080280004d08a7674", now),
        &[
            Output::Wake(now + Duration::from_secs(3600)),
            Output::CreateAllocation(("35.124.91.37:49152", "[2600:1f18:f96:e710:2a51:e8f:7303:6942]:49152")),
            Output::SendMessage(("91.141.70.157:7112", "010300382112a44215d4bb014ad31072cd248ec7001600080001e112026eff67001600140002e1120712bb5a1a425c1160821efdbe27e7850020000800013ada7a9fe2df000d000400000e10")),
        ],
    )]);
}

#[test]
fn deallocate_once_time_expired() {
    let now = Instant::now();

    run_regression_test(&[(
        Input::Client("91.141.70.157:7112", "000300182112a44215d4bb014ad31072cd248ec70019000411000000000d000400000e1080280004d08a7674", now),
        &[
            Output::Wake(now + Duration::from_secs(3600)),
            Output::CreateAllocation(("35.124.91.37:49152", "[2600:1f18:f96:e710:2a51:e8f:7303:6942]:49152")),
            Output::SendMessage(("91.141.70.157:7112", "010300382112a44215d4bb014ad31072cd248ec7001600080001e112026eff67001600140002e1120712bb5a1a425c1160821efdbe27e7850020000800013ada7a9fe2df000d000400000e10")),
        ],
    ), (
        Input::Time(now + Duration::from_secs(3601)),
        &[
            Output::ExpireAllocation(("35.124.91.37:49152", "[2600:1f18:f96:e710:2a51:e8f:7303:6942]:49152"))
        ],
    )]);
}

/// Run a regression test with a sequence events where we always have 1 input and N outputs.
fn run_regression_test(sequence: &[(Input, &[Output])]) {
    let mut server = Server::test();

    let mut allocatio_mapping = HashMap::<(Ip, Ip), AllocationId>::default();

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
            let actual_output = server.next_command().expect(&format!(
                "no commands produced but expected {expected_output:?}"
            ));

            match (expected_output, actual_output) {
                (Output::SendMessage((to, bytes)), Command::SendMessage { payload, recipient }) => {
                    assert_eq!(*bytes, hex::encode(payload));
                    assert_eq!(recipient, to.parse().unwrap());
                }
                (
                    Output::CreateAllocation((expected_ip4, expected_ip6)),
                    Command::AllocateAddresses { ip4, ip6, id },
                ) => {
                    assert_eq!(ip4, expected_ip4.parse().unwrap());
                    assert_eq!(ip6, expected_ip6.parse().unwrap());

                    allocatio_mapping.insert((expected_ip4, expected_ip6), id);
                }
                (Output::Wake(expected), Command::Wake { deadline }) => {
                    assert_eq!(*expected, deadline);
                }
                (Output::ExpireAllocation((ip4, ip6)), Command::FreeAddresses { id }) => {
                    let expected_id = allocatio_mapping
                        .remove(&(ip4, ip6))
                        .expect("unknown allocation");

                    assert_eq!(expected_id, id);
                }
                (expected, actual) => panic!("Unhandled events: {expected:?} and {actual:?}"),
            }
        }

        assert!(server.next_command().is_none())
    }
}

enum Input {
    Client(Ip, Bytes, Instant),
    Time(Instant),
}

#[derive(Debug)]
enum Output {
    SendMessage((Ip, Bytes)),
    Wake(Instant),
    CreateAllocation((Ip, Ip)),
    ExpireAllocation((Ip, Ip)),
}

type Ip = &'static str;
type Bytes = &'static str;
