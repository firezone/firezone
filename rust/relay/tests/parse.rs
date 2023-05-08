use hex_literal::hex;

#[test]
fn parse_sample_stun_binding_request_without_attributes() {
    let message = hex!("010100002112A442B17E7A701BC34D68FF04A1E4");

    let (input, message) = relay::stun::parse_binding_request(&message).unwrap();

    assert_eq!(input, &[]);
    assert_eq!(message.transaction_id, &hex!("B17E7A701BC34D68FF04A1E4"));
}
