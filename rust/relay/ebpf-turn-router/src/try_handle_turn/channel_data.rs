#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct CdHdr {
    pub number: [u8; 2],
    pub length: [u8; 2],
}

impl CdHdr {
    pub const LEN: usize = core::mem::size_of::<Self>();

    pub fn number(&self) -> u16 {
        u16::from_be_bytes(self.number)
    }

    pub fn length(&self) -> u16 {
        u16::from_be_bytes(self.length)
    }
}
