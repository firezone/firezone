use hex_literal::hex;
use std::net::SocketAddr;

#[test]
fn parse_sample_stun_binding_request_without_attributes() {
    let message = hex!("010100002112A442B17E7A701BC34D68FF04A1E4");

    let (input, message) = relay::stun::parse_binding_request(&message).unwrap();

    assert_eq!(input, &[]);
    assert_eq!(message.transaction_id, &hex!("B17E7A701BC34D68FF04A1E4"));
}

#[test]
fn serialize_stun_binding_response_for_ip4() {
    let buffer = relay::stun::write_binding_response(
        &hex!("B17E7A701BC34D68FF04A1E4"),
        SocketAddr::from(([128, 193, 33, 95], 52253)),
    );

    assert_eq!(buffer, hex!("010100482112A442B17E7A701BC34D68FF04A1E400200008e1d4c3c41d1a"));
}

#[test]
fn serialize_stun_binding_response_for_ip6() {
    let buffer = relay::stun::write_binding_response(
        &hex!("B17E7A701BC34D68FF04A1E4"),
        "[2001:0db8:0024:0003:0005:a14f:6d74:0000]:52253"
            .parse()
            .unwrap()
    );

    assert_eq!(buffer, hex!("20010db800240003000500a14f6d740021001420010db800240003000500a14f6d7408a6b1ae91f5021e"));
}
