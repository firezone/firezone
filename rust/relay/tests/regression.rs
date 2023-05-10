use relay::server::{Command, Server};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};

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
    let mut server = Server::new(
        SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0),
        SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0),
    );

    for (Input(from, input), output) in pairs {
        let input = hex::decode(input).unwrap();
        let from = from.parse().unwrap();

        server.handle_client_input(&input, from).unwrap();

        for expected_output in *output {
            let actual_output = server.next_command().unwrap();

            match (expected_output, actual_output) {
                (Output::SendMessage((to, bytes)), Command::SendMessage { payload, recipient }) => {
                    assert_eq!(*bytes, hex::encode(payload));
                    assert_eq!(recipient, to.parse().unwrap());
                }
                _ => unimplemented!(),
            }
        }

        assert!(server.next_command().is_none())
    }
}

struct Input(Ip, Bytes);

enum Output {
    SendMessage((Ip, Bytes)),
}

type Ip = &'static str;
type Bytes = &'static str;
