use ip_packet::IpPacket;

/// Build an echo reply for a UDP/TCP request by swapping source and destination
/// addresses and ports.
///
/// Returns `None` for packets that are neither UDP nor TCP — those are not
/// suitable for the simple swap-and-reply pattern.
pub(crate) fn echo_reply(mut req: IpPacket) -> Option<IpPacket> {
    if !req.is_udp() && !req.is_tcp() {
        return None;
    }

    if let Some(mut packet) = req.as_tcp_mut() {
        let original_src = packet.get_source_port();
        let original_dst = packet.get_destination_port();

        packet.set_source_port(original_dst);
        packet.set_destination_port(original_src);
    }

    if let Some(mut packet) = req.as_udp_mut() {
        let original_src = packet.get_source_port();
        let original_dst = packet.get_destination_port();

        packet.set_source_port(original_dst);
        packet.set_destination_port(original_src);
    }

    let original_src = req.source();
    let original_dst = req.destination();

    req.set_dst(original_src).unwrap();
    req.set_src(original_dst).unwrap();

    Some(req)
}
