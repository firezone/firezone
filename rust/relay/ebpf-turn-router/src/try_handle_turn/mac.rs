use network_types::eth::EthHdr;

/// Reads and writes the MAC addresses of an Ethernet header as a single [`MacAddrs`].
///
/// This is the API we would like [`EthHdr`] itself to have, so it can move to `network-types`.
pub trait EthHdrExt {
    fn mac_addrs(&self) -> MacAddrs;
    fn set_mac_addrs(&mut self, addrs: MacAddrs);
}

impl EthHdrExt for EthHdr {
    #[inline(always)]
    fn mac_addrs(&self) -> MacAddrs {
        MacAddrs {
            dst: to_u64(&self.dst_addr),
            src: to_u64(&self.src_addr),
        }
    }

    #[inline(always)]
    fn set_mac_addrs(&mut self, addrs: MacAddrs) {
        write(&mut self.dst_addr, addrs.dst);
        write(&mut self.src_addr, addrs.src);
    }
}

/// The destination and source MAC addresses of an Ethernet header.
///
/// Copying the address arrays from one header to another compiles to calls to `memmove`, which
/// are comparatively expensive, especially with mitigations against speculative execution.
/// Instead, we hold each address in an integer that fits into a register.
#[derive(Clone, Copy)]
pub struct MacAddrs {
    dst: u64,
    src: u64,
}

impl MacAddrs {
    /// The addresses of a frame that goes back to where this one came from.
    #[inline(always)]
    pub fn swapped(self) -> Self {
        Self {
            dst: self.src,
            src: self.dst,
        }
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
