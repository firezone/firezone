use relay::{Command, Server};
use std::time::{Duration, Instant};

#[test]
fn stun_binding_request() {
    run_regression_test(&[(
        Input(
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
        Input("91.141.70.157:7112", "000300182112a44215d4bb014ad31072cd248ec70019000411000000000d000400000e1080280004d08a7674", now),
        &[
            Output::Wake(now + Duration::from_secs(3600)),
            Output::CreateAllocation(("35.124.91.37:49152", "[2600:1f18:f96:e710:2a51:e8f:7303:6942]:49152")),
            Output::SendMessage(("91.141.70.157:7112", "010300382112a44215d4bb014ad31072cd248ec7001600080001e112026eff67001600140002e1120712bb5a1a425c1160821efdbe27e7850020000800013ada7a9fe2df000d000400000e10")),
        ],
    )]);
}

fn run_regression_test(pairs: &[(Input, &[Output])]) {
    let mut server = Server::test();

    for (Input(from, input, now), output) in pairs {
        let input = hex::decode(input).unwrap();
        let from = from.parse().unwrap();

        server.handle_client_input(&input, from, *now).unwrap();

        for expected_output in *output {
            let actual_output = server.next_command().unwrap();

            match (expected_output, actual_output) {
                (Output::SendMessage((to, bytes)), Command::SendMessage { payload, recipient }) => {
                    assert_eq!(*bytes, hex::encode(payload));
                    assert_eq!(recipient, to.parse().unwrap());
                }
                (
                    Output::CreateAllocation((expected_ip4, expected_ip6)),
                    Command::AllocateAddresses { ip4, ip6, .. },
                ) => {
                    assert_eq!(ip4, expected_ip4.parse().unwrap());
                    assert_eq!(ip6, expected_ip6.parse().unwrap());
                }
                (Output::Wake(expected), Command::Wake { deadline }) => {
                    assert_eq!(*expected, deadline);
                }
                (expected, actual) => panic!("Unhandled events: {expected:?} and {actual:?}"),
            }
        }

        assert!(server.next_command().is_none())
    }
}

struct Input(Ip, Bytes, Instant);

#[derive(Debug)]
enum Output {
    SendMessage((Ip, Bytes)),
    Wake(Instant),
    CreateAllocation((Ip, Ip)),
}

type Ip = &'static str;
type Bytes = &'static str;
