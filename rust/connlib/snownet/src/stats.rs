use std::ops::AddAssign;

#[derive(Default, Debug, Clone, Copy)]
pub struct NodeStats {
    /// How many bytes we sent as part of exchanging STUN messages with relays (control messages only).
    pub stun_bytes_to_relays: HumanBytes,
}

#[derive(Default, Debug, Clone, Copy)]
pub struct ConnectionStats {
    /// How many bytes we sent as part of exchanging STUN messages to other peers directly.
    pub stun_bytes_to_peer_direct: HumanBytes,
    /// How many bytes we sent as part of exchanging STUN messages to other peers via relays.
    pub stun_bytes_to_peer_relayed: HumanBytes,
}

#[derive(Default, Clone, Copy)]
pub struct HumanBytes(pub usize);

impl std::fmt::Debug for HumanBytes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", fmt_human_bytes(self.0 as f64))
    }
}

impl AddAssign<usize> for HumanBytes {
    fn add_assign(&mut self, rhs: usize) {
        self.0 += rhs;
    }
}

fn fmt_human_bytes(mut throughput: f64) -> String {
    let units = ["B", "kB", "MB", "GB", "TB"];

    for unit in units {
        if throughput < 1000.0 {
            return format!("{throughput:.2} {unit}");
        }

        throughput /= 1000.0;
    }

    format!("{throughput:.2} TB")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fmt_human_bytes() {
        assert_eq!(format!("{:?}", HumanBytes(0)), "0.00 B");
        assert_eq!(format!("{:?}", HumanBytes(1_000)), "1.00 kB");
        assert_eq!(format!("{:?}", HumanBytes(12_500_000)), "12.50 MB");
    }
}
