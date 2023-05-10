use relay::server::{Event, Server};
use std::net::SocketAddrV4;

#[test]
fn stun_binding_request() {
    run_regression_test(&[(
        Input(
            "91.141.64.64:26098",
            "000100002112a4420908af7d45e8751f5092d167",
        ),
        &[Output::SendMessage((
            "91.141.64.64:26098",
            "0101000c2112a4420908af7d45e8751f5092d16700200008000144e07a9fe402",
        ))],
    )]);
}

fn run_regression_test(pairs: &[(Input, &[Output])]) {
    let mut server = Server::new("0.0.0.0:0".parse::<SocketAddrV4>().unwrap());

    for (Input(from, input), output) in pairs {
        let input = hex::decode(input).unwrap();
        let from = from.parse().unwrap();

        server.handle_received_bytes(&input, from).unwrap();

        for expected_output in *output {
            let actual_output = server.next_event().unwrap();

            match (expected_output, actual_output) {
                (Output::SendMessage((to, bytes)), Event::SendMessage { payload, recipient }) => {
                    assert_eq!(*bytes, hex::encode(payload));
                    assert_eq!(recipient, to.parse().unwrap());
                }
            }
        }

        assert!(server.next_event().is_none())
    }
}

struct Input(Ip, Bytes);

enum Output {
    SendMessage((Ip, Bytes)),
}

type Ip = &'static str;
type Bytes = &'static str;
