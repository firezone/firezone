use network_types::eth::EthHdr;

/// The source and destination MAC addresses of an Ethernet header.
///
/// Copying the address arrays from one header to another compiles to calls to `memmove`, which
/// are comparatively expensive, especially with mitigations against speculative execution.
/// Instead, we copy them through registers.
#[derive(Clone, Copy)]
pub struct MacAddrs {
    src: u64,
    dst: u64,
}

impl MacAddrs {
    #[inline(always)]
    pub fn read(eth: &EthHdr) -> Self {
        Self {
            src: to_u64(&eth.src_addr),
            dst: to_u64(&eth.dst_addr),
        }
    }

    /// Writes the addresses swapped, i.e. sends the packet back to where it came from.
    #[inline(always)]
    pub fn write_swapped(self, eth: &mut EthHdr) {
        write(&mut eth.src_addr, self.dst);
        write(&mut eth.dst_addr, self.src);
    }
}

#[inline(always)]
fn to_u64(mac: &[u8; 6]) -> u64 {
    u64::from_le_bytes([mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], 0, 0])
}

#[inline(always)]
fn write(mac: &mut [u8; 6], value: u64) {
    let [b0, b1, b2, b3, b4, b5, _, _] = value.to_le_bytes();

    mac[0] = b0;
    mac[1] = b1;
    mac[2] = b2;
    mac[3] = b3;
    mac[4] = b4;
    mac[5] = b5;
}
