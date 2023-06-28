//! Additions to the `stun-codec` crate for RFC 8656.
//
// TODO: Upstream this to `stun-codec`.

use bytecodec::fixnum::{U32beDecoder, U32beEncoder};
use bytecodec::{ByteCount, Decode, Encode, Eos, ErrorKind, Result, SizedEncode, TryTaggedDecode};
use stun_codec::rfc5389::attributes::ErrorCode;
use stun_codec::{Attribute, AttributeType};
use trackable::{track, track_panic};

macro_rules! impl_decode {
    ($decoder:ty, $item:ident, $and_then:expr) => {
        impl Decode for $decoder {
            type Item = $item;

            fn decode(&mut self, buf: &[u8], eos: Eos) -> Result<usize> {
                track!(self.0.decode(buf, eos))
            }

            fn finish_decoding(&mut self) -> Result<Self::Item> {
                track!(self.0.finish_decoding()).and_then($and_then)
            }

            fn requiring_bytes(&self) -> ByteCount {
                self.0.requiring_bytes()
            }

            fn is_idle(&self) -> bool {
                self.0.is_idle()
            }
        }
        impl TryTaggedDecode for $decoder {
            type Tag = AttributeType;

            fn try_start_decoding(&mut self, attr_type: Self::Tag) -> Result<bool> {
                Ok(attr_type.as_u16() == $item::CODEPOINT)
            }
        }
    };
}

macro_rules! impl_encode {
    ($encoder:ty, $item:ty, $map_from:expr) => {
        impl Encode for $encoder {
            type Item = $item;

            fn encode(&mut self, buf: &mut [u8], eos: Eos) -> Result<usize> {
                track!(self.0.encode(buf, eos))
            }

            fn start_encoding(&mut self, item: Self::Item) -> Result<()> {
                track!(self.0.start_encoding($map_from(item).into()))
            }

            fn requiring_bytes(&self) -> ByteCount {
                self.0.requiring_bytes()
            }

            fn is_idle(&self) -> bool {
                self.0.is_idle()
            }
        }
        impl SizedEncode for $encoder {
            fn exact_requiring_bytes(&self) -> u64 {
                self.0.exact_requiring_bytes()
            }
        }
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PeerAddressFamilyMismatch;
impl PeerAddressFamilyMismatch {
    /// The codepoint of the error.
    pub const CODEPOINT: u16 = 443;
}
impl From<PeerAddressFamilyMismatch> for ErrorCode {
    fn from(_: PeerAddressFamilyMismatch) -> Self {
        ErrorCode::new(
            PeerAddressFamilyMismatch::CODEPOINT,
            "Peer Address Family Mismatch".to_owned(),
        )
        .expect("never fails")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AddressFamily {
    V4,
    V6,
}

const FAMILY_IPV4: u8 = 1;
const FAMILY_IPV6: u8 = 2;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RequestedAddressFamily(AddressFamily);
impl RequestedAddressFamily {
    /// The codepoint of the type of the attribute.
    pub const CODEPOINT: u16 = 0x0017;

    /// Makes a new `RequestedAddressFamily` instance.
    pub fn new(fam: AddressFamily) -> Self {
        RequestedAddressFamily(fam)
    }

    /// Returns the requested address family.
    pub fn address_family(&self) -> AddressFamily {
        self.0
    }
}
impl Attribute for RequestedAddressFamily {
    type Decoder = RequestedAddressFamilyDecoder;
    type Encoder = RequestedAddressFamilyEncoder;

    fn get_type(&self) -> AttributeType {
        AttributeType::new(Self::CODEPOINT)
    }
}

/// [`RequestedAddressFamily`] decoder.
#[derive(Debug, Default)]
pub struct RequestedAddressFamilyDecoder(AddressFamilyDecoder);
impl RequestedAddressFamilyDecoder {
    /// Makes a new `RequestedAddressFamilyDecoder` instance.
    pub fn new() -> Self {
        Self::default()
    }
}
impl_decode!(
    RequestedAddressFamilyDecoder,
    RequestedAddressFamily,
    |item| Ok(RequestedAddressFamily(item))
);

/// [`RequestedAddressFamily`] encoder.
#[derive(Debug, Default)]
pub struct RequestedAddressFamilyEncoder(AddressFamilyEncoder);
impl RequestedAddressFamilyEncoder {
    /// Makes a new `RequestedAddressFamilyEncoder` instance.
    pub fn new() -> Self {
        Self::default()
    }
}
impl_encode!(
    RequestedAddressFamilyEncoder,
    RequestedAddressFamily,
    |item: Self::Item| { item.0 }
);

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AdditionalAddressFamily(AddressFamily);
impl AdditionalAddressFamily {
    /// The codepoint of the type of the attribute.
    pub const CODEPOINT: u16 = 0x8000;

    /// Makes a new `AdditionalAddressFamily` instance.
    pub fn new(fam: AddressFamily) -> Self {
        AdditionalAddressFamily(fam)
    }

    /// Returns the requested address family.
    pub fn address_family(&self) -> AddressFamily {
        self.0
    }
}
impl Attribute for AdditionalAddressFamily {
    type Decoder = AdditionalAddressFamilyDecoder;
    type Encoder = AdditionalAddressFamilyEncoder;

    fn get_type(&self) -> AttributeType {
        AttributeType::new(Self::CODEPOINT)
    }
}

/// [`AdditionalAddressFamily`] decoder.
#[derive(Debug, Default)]
pub struct AdditionalAddressFamilyDecoder(AddressFamilyDecoder);

impl_decode!(
    AdditionalAddressFamilyDecoder,
    AdditionalAddressFamily,
    |item| Ok(AdditionalAddressFamily(item))
);

/// [`AdditionalAddressFamily`] encoder.
#[derive(Debug, Default)]
pub struct AdditionalAddressFamilyEncoder(AddressFamilyEncoder);
impl_encode!(
    AdditionalAddressFamilyEncoder,
    AdditionalAddressFamily,
    |item: Self::Item| { item.0 }
);

/// [`RequestedAddressFamily`] decoder.
#[derive(Debug, Default)]
pub struct AddressFamilyDecoder {
    family: U32beDecoder,
}

impl Decode for AddressFamilyDecoder {
    type Item = AddressFamily;

    fn decode(&mut self, buf: &[u8], eos: Eos) -> Result<usize> {
        self.family.decode(buf, eos)
    }

    fn finish_decoding(&mut self) -> Result<Self::Item> {
        let [fam, _, _, _] = self.family.finish_decoding()?.to_be_bytes();

        match fam {
            FAMILY_IPV4 => Ok(AddressFamily::V4),
            FAMILY_IPV6 => Ok(AddressFamily::V6),
            family => track_panic!(
                ErrorKind::InvalidInput,
                "Unknown address family: {}",
                family
            ),
        }
    }

    fn requiring_bytes(&self) -> ByteCount {
        self.family.requiring_bytes()
    }

    fn is_idle(&self) -> bool {
        self.family.is_idle()
    }
}

/// [`RequestedAddressFamily`] decoder.
#[derive(Debug, Default)]
pub struct AddressFamilyEncoder {
    family: U32beEncoder,
}

impl Encode for AddressFamilyEncoder {
    type Item = AddressFamily;

    fn encode(&mut self, buf: &mut [u8], eos: Eos) -> Result<usize> {
        self.family.encode(buf, eos)
    }

    fn start_encoding(&mut self, item: Self::Item) -> Result<()> {
        let fam_byte = match item {
            AddressFamily::V4 => FAMILY_IPV4,
            AddressFamily::V6 => FAMILY_IPV6,
        };

        let bytes = [fam_byte, 0, 0, 0];

        self.family.start_encoding(u32::from_be_bytes(bytes))
    }

    fn requiring_bytes(&self) -> ByteCount {
        ByteCount::Finite(self.exact_requiring_bytes())
    }
}

impl SizedEncode for AddressFamilyEncoder {
    fn exact_requiring_bytes(&self) -> u64 {
        self.family.exact_requiring_bytes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytecodec::{DecodeExt, EncodeExt};

    #[test]
    fn address_family_encoder_works() {
        let mut encoder = AddressFamilyEncoder::default();

        let bytes = encoder.encode_into_bytes(AddressFamily::V4).unwrap();
        assert_eq!(bytes, [1, 0, 0, 0]);

        let bytes = encoder.encode_into_bytes(AddressFamily::V6).unwrap();
        assert_eq!(bytes, [2, 0, 0, 0]);
    }

    #[test]
    fn address_family_decoder_works() {
        let mut decoder = AddressFamilyDecoder::default();

        let fam = decoder.decode_from_bytes(&[1, 0, 0, 0]).unwrap();
        assert_eq!(fam, AddressFamily::V4);

        let fam = decoder.decode_from_bytes(&[2, 0, 0, 0]).unwrap();
        assert_eq!(fam, AddressFamily::V6);
    }
}
