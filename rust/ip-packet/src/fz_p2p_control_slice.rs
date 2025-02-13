use etherparse::LenSource;

use crate::FzP2pEventType;

pub struct FzP2pControlSlice<'a> {
    slice: &'a [u8],
}

impl<'a> FzP2pControlSlice<'a> {
    /// Creates a new [`FzP2pControlSlice`].
    pub fn from_slice(slice: &'a [u8]) -> Result<Self, etherparse::err::LenError> {
        if slice.len() < 8 {
            return Err(etherparse::err::LenError {
                required_len: 8,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: etherparse::err::Layer::Ipv6Header,
                layer_start_offset: 0,
            });
        }

        Ok(Self { slice })
    }

    pub fn event_type(&self) -> FzP2pEventType {
        FzP2pEventType::new(self.slice[0])
    }

    pub fn payload(&self) -> &[u8] {
        let (_, payload) = self.slice.split_at(8);

        payload
    }
}
