use relay::server::Server;

#[test]
fn stun_binding_request() {
    run_regression_test(&[(
        Input(
            "91.141.64.64:26098",
            "000100002112a4420908af7d45e8751f5092d167",
        ),
        Output(
            "91.141.64.64:26098",
            "0101000c2112a4420908af7d45e8751f5092d16700200008000144e07a9fe402",
        ),
    )]);
}

fn run_regression_test(pairs: &[(Input, Output)]) {
    let mut server = Server::default();

    for (Input(from, input), Output(to, output)) in pairs {
        let input = hex::decode(input).unwrap();
        let from = from.parse().unwrap();
        let output = hex::decode(output).unwrap();
        let to = to.parse().unwrap();

        let (response, recipient) = server.handle_received_bytes(&input, from).unwrap().unwrap();

        assert_eq!(response, output);
        assert_eq!(recipient, to);
    }
}

struct Input(Ip, Bytes);

struct Output(Ip, Bytes);

type Ip = &'static str;
type Bytes = &'static str;
