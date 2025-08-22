#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct CdHdr {
    pub number: [u8; 2],
    pub length: [u8; 2],
}

impl CdHdr {
    pub const LEN: usize = core::mem::size_of::<Self>();
}
