//! Typed representations of ICMP and ICMPv6 messages.
//!
//! The wire format of both protocols is a 4-byte header (type, code, checksum)
//! followed by 4 bytes whose meaning depends on the message type.
//! [`Icmpv4Type`] and [`Icmpv6Type`] decode the message types we care about and
//! fall back to [`Icmpv4Type::Unknown`] / [`Icmpv6Type::Unknown`] for everything else,
//! preserving the raw bytes so that re-serialising a message is always lossless.

/// The `identifier` and `sequence number` of an ICMP(v6) echo request / reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IcmpEchoHeader {
    pub id: u16,
    pub seq: u16,
}

impl IcmpEchoHeader {
    fn from_bytes(bytes: [u8; 4]) -> Self {
        Self {
            id: u16::from_be_bytes([bytes[0], bytes[1]]),
            seq: u16::from_be_bytes([bytes[2], bytes[3]]),
        }
    }

    fn to_bytes(self) -> [u8; 4] {
        let [id0, id1] = self.id.to_be_bytes();
        let [seq0, seq1] = self.seq.to_be_bytes();

        [id0, id1, seq0, seq1]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Icmpv4Type {
    EchoReply(IcmpEchoHeader),
    EchoRequest(IcmpEchoHeader),
    DestinationUnreachable(icmpv4::DestUnreachableHeader),
    TimeExceeded(icmpv4::TimeExceededCode),
    Unknown {
        ty: u8,
        code: u8,
        rest_of_header: [u8; 4],
    },
}

impl Icmpv4Type {
    const ECHO_REPLY: u8 = 0;
    const DEST_UNREACHABLE: u8 = 3;
    const ECHO_REQUEST: u8 = 8;
    const TIME_EXCEEDED: u8 = 11;

    pub(crate) fn from_wire(ty: u8, code: u8, rest_of_header: [u8; 4]) -> Self {
        match (ty, code) {
            (Self::ECHO_REPLY, 0) => Self::EchoReply(IcmpEchoHeader::from_bytes(rest_of_header)),
            (Self::ECHO_REQUEST, 0) => {
                Self::EchoRequest(IcmpEchoHeader::from_bytes(rest_of_header))
            }
            (Self::DEST_UNREACHABLE, code) => Self::DestinationUnreachable(
                icmpv4::DestUnreachableHeader::from_wire(code, rest_of_header),
            ),
            (Self::TIME_EXCEEDED, code) => Self::TimeExceeded(icmpv4::TimeExceededCode(code)),
            (ty, code) => Self::Unknown {
                ty,
                code,
                rest_of_header,
            },
        }
    }

    pub(crate) fn to_wire(self) -> (u8, u8, [u8; 4]) {
        match self {
            Self::EchoReply(echo) => (Self::ECHO_REPLY, 0, echo.to_bytes()),
            Self::EchoRequest(echo) => (Self::ECHO_REQUEST, 0, echo.to_bytes()),
            Self::DestinationUnreachable(header) => {
                let (code, rest) = header.to_wire();

                (Self::DEST_UNREACHABLE, code, rest)
            }
            Self::TimeExceeded(code) => (Self::TIME_EXCEEDED, code.0, [0u8; 4]),
            Self::Unknown {
                ty,
                code,
                rest_of_header,
            } => (ty, code, rest_of_header),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Icmpv6Type {
    DestinationUnreachable(icmpv6::DestUnreachableCode),
    PacketTooBig {
        mtu: u32,
    },
    TimeExceeded(icmpv6::TimeExceededCode),
    EchoRequest(IcmpEchoHeader),
    EchoReply(IcmpEchoHeader),
    Unknown {
        ty: u8,
        code: u8,
        rest_of_header: [u8; 4],
    },
}

impl Icmpv6Type {
    const DEST_UNREACHABLE: u8 = 1;
    const PACKET_TOO_BIG: u8 = 2;
    const TIME_EXCEEDED: u8 = 3;
    const ECHO_REQUEST: u8 = 128;
    const ECHO_REPLY: u8 = 129;

    pub(crate) fn from_wire(ty: u8, code: u8, rest_of_header: [u8; 4]) -> Self {
        match (ty, code) {
            (Self::DEST_UNREACHABLE, code) => {
                Self::DestinationUnreachable(icmpv6::DestUnreachableCode::from_wire(code))
            }
            (Self::PACKET_TOO_BIG, 0) => Self::PacketTooBig {
                mtu: u32::from_be_bytes(rest_of_header),
            },
            (Self::TIME_EXCEEDED, code) => Self::TimeExceeded(icmpv6::TimeExceededCode(code)),
            (Self::ECHO_REQUEST, 0) => {
                Self::EchoRequest(IcmpEchoHeader::from_bytes(rest_of_header))
            }
            (Self::ECHO_REPLY, 0) => Self::EchoReply(IcmpEchoHeader::from_bytes(rest_of_header)),
            (ty, code) => Self::Unknown {
                ty,
                code,
                rest_of_header,
            },
        }
    }

    pub(crate) fn to_wire(self) -> (u8, u8, [u8; 4]) {
        match self {
            Self::DestinationUnreachable(code) => {
                (Self::DEST_UNREACHABLE, code.to_wire(), [0u8; 4])
            }
            Self::PacketTooBig { mtu } => (Self::PACKET_TOO_BIG, 0, mtu.to_be_bytes()),
            Self::TimeExceeded(code) => (Self::TIME_EXCEEDED, code.0, [0u8; 4]),
            Self::EchoRequest(echo) => (Self::ECHO_REQUEST, 0, echo.to_bytes()),
            Self::EchoReply(echo) => (Self::ECHO_REPLY, 0, echo.to_bytes()),
            Self::Unknown {
                ty,
                code,
                rest_of_header,
            } => (ty, code, rest_of_header),
        }
    }
}

pub mod icmpv4 {
    //! Codes for ICMP messages, see <https://www.rfc-editor.org/rfc/rfc792>.

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum DestUnreachableHeader {
        /// Code 0: Net unreachable.
        Network,
        /// Code 1: Host unreachable.
        Host,
        /// Code 3: Port unreachable.
        Port,
        /// Code 4: Fragmentation needed and DF set.
        FragmentationNeeded {
            next_hop_mtu: u16,
        },
        /// Code 13: Communication administratively prohibited.
        FilterProhibited,
        Other {
            code: u8,
        },
    }

    impl DestUnreachableHeader {
        pub(crate) fn from_wire(code: u8, rest_of_header: [u8; 4]) -> Self {
            match code {
                0 => Self::Network,
                1 => Self::Host,
                3 => Self::Port,
                4 => Self::FragmentationNeeded {
                    next_hop_mtu: u16::from_be_bytes([rest_of_header[2], rest_of_header[3]]),
                },
                13 => Self::FilterProhibited,
                code => Self::Other { code },
            }
        }

        pub(crate) fn to_wire(self) -> (u8, [u8; 4]) {
            match self {
                Self::Network => (0, [0u8; 4]),
                Self::Host => (1, [0u8; 4]),
                Self::Port => (3, [0u8; 4]),
                Self::FragmentationNeeded { next_hop_mtu } => {
                    let [mtu0, mtu1] = next_hop_mtu.to_be_bytes();

                    (4, [0, 0, mtu0, mtu1])
                }
                Self::FilterProhibited => (13, [0u8; 4]),
                Self::Other { code } => (code, [0u8; 4]),
            }
        }

        pub fn code_u8(&self) -> u8 {
            self.to_wire().0
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct TimeExceededCode(pub u8);

    impl TimeExceededCode {
        /// Code 0: Time to live exceeded in transit.
        pub const TTL_EXCEEDED_IN_TRANSIT: Self = Self(0);

        pub fn code_u8(&self) -> u8 {
            self.0
        }
    }
}

pub mod icmpv6 {
    //! Codes for ICMPv6 messages, see <https://www.rfc-editor.org/rfc/rfc4443>.

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum DestUnreachableCode {
        /// Code 0: No route to destination.
        NoRoute,
        /// Code 1: Communication with destination administratively prohibited.
        Prohibited,
        /// Code 2: Beyond scope of source address.
        BeyondScope,
        /// Code 3: Address unreachable.
        Address,
        /// Code 4: Port unreachable.
        Port,
        Other {
            code: u8,
        },
    }

    impl DestUnreachableCode {
        pub(crate) fn from_wire(code: u8) -> Self {
            match code {
                0 => Self::NoRoute,
                1 => Self::Prohibited,
                2 => Self::BeyondScope,
                3 => Self::Address,
                4 => Self::Port,
                code => Self::Other { code },
            }
        }

        pub(crate) fn to_wire(self) -> u8 {
            match self {
                Self::NoRoute => 0,
                Self::Prohibited => 1,
                Self::BeyondScope => 2,
                Self::Address => 3,
                Self::Port => 4,
                Self::Other { code } => code,
            }
        }

        pub fn code_u8(&self) -> u8 {
            self.to_wire()
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct TimeExceededCode(pub u8);

    impl TimeExceededCode {
        /// Code 0: Hop limit exceeded in transit.
        pub const HOP_LIMIT_EXCEEDED: Self = Self(0);

        pub fn code_u8(&self) -> u8 {
            self.0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn icmpv4_wire_roundtrip() {
        let types = [
            Icmpv4Type::EchoReply(IcmpEchoHeader { id: 1, seq: 2 }),
            Icmpv4Type::EchoRequest(IcmpEchoHeader { id: 3, seq: 4 }),
            Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Network),
            Icmpv4Type::DestinationUnreachable(
                icmpv4::DestUnreachableHeader::FragmentationNeeded { next_hop_mtu: 1280 },
            ),
            Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Other { code: 7 }),
            Icmpv4Type::TimeExceeded(icmpv4::TimeExceededCode(1)),
            Icmpv4Type::Unknown {
                ty: 42,
                code: 3,
                rest_of_header: [1, 2, 3, 4],
            },
        ];

        for ty in types {
            let (t, c, rest) = ty.to_wire();

            assert_eq!(Icmpv4Type::from_wire(t, c, rest), ty);
        }
    }

    #[test]
    fn icmpv6_wire_roundtrip() {
        let types = [
            Icmpv6Type::EchoReply(IcmpEchoHeader { id: 1, seq: 2 }),
            Icmpv6Type::EchoRequest(IcmpEchoHeader { id: 3, seq: 4 }),
            Icmpv6Type::DestinationUnreachable(icmpv6::DestUnreachableCode::Port),
            Icmpv6Type::PacketTooBig { mtu: 1280 },
            Icmpv6Type::TimeExceeded(icmpv6::TimeExceededCode(0)),
            Icmpv6Type::Unknown {
                ty: 200,
                code: 3,
                rest_of_header: [1, 2, 3, 4],
            },
        ];

        for ty in types {
            let (t, c, rest) = ty.to_wire();

            assert_eq!(Icmpv6Type::from_wire(t, c, rest), ty);
        }
    }
}
