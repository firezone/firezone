use stun_codec::define_attribute_enums;
use stun_codec::rfc5389::attributes::{MessageIntegrity, XorMappedAddress};

define_attribute_enums!(
    Attribute,
    AttributeDecoder,
    AttributeEncoder,
    [MessageIntegrity, XorMappedAddress]
);
