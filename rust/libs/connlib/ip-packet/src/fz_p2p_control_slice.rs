use crate::FzP2pEventType;

pub struct FzP2pControlSlice<'a> {
    slice: &'a [u8],
}

impl<'a> FzP2pControlSlice<'a> {
    /// Creates a new [`FzP2pControlSlice`].
    pub fn from_slice(slice: &'a [u8]) -> Result<Self, TooShort> {
        if slice.len() < 8 {
            return Err(TooShort { len: slice.len() });
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

#[derive(Debug, thiserror::Error)]
#[error("FZ p2p control packets require an 8-byte header (len: {len})")]
pub struct TooShort {
    len: usize,
}
