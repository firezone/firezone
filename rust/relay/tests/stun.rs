use hex_literal::hex;

#[test]
fn parse_sample_stun_binding_request_without_attributes() {
    let message = hex!("000100002112A442B17E7A701BC34D68FF04A1E4");

    let (input, message) = relay::stun::parse_binding_request(&message).unwrap();

    assert_eq!(input, &[]);
    assert_eq!(message.transaction_id, &hex!("B17E7A701BC34D68FF04A1E4"));
}

#[test]
fn serialize_stun_binding_response_for_ip4() {
    let buffer = relay::stun::write_binding_response(
        &hex!("B17E7A701BC34D68FF04A1E4"),
        "128.193.33.95:52253".parse().unwrap(),
    );

    assert_eq!(
        hex::encode(buffer),
        "0101000c2112a442b17e7a701bc34d68ff04a1e4002000080001ed0fa1d3851d"
    );
}

#[test]
fn serialize_stun_binding_response_for_ip6() {
    let buffer = relay::stun::write_binding_response(
        &hex!("B17E7A701BC34D68FF04A1E4"),
        "[2001:0db8:0024:0003:0005:a14f:6d74:0000]:52253"
            .parse()
            .unwrap(),
    );

    assert_eq!(
        hex::encode(buffer),
        "010100182112a442b17e7a701bc34d68ff04a1e4002000140002ed0f0113a9fab15a7a731bc6ec279270a1e4"
    );
}
