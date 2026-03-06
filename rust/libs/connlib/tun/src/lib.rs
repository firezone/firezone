
use ip_packet::IpPacket;

#[cfg(target_family = "unix")]
pub mod ioctl;
#[cfg(target_family = "unix")]
pub mod unix;

pub trait Tun: Send + Sync + 'static {
    /// Get a reference to the sender for outbound packets.
    fn sender(&self) -> &tokio::sync::mpsc::Sender<IpPacket>;

    /// Get a mutable reference to the receiver for inbound packets.
    fn receiver(&mut self) -> &mut tokio::sync::mpsc::Receiver<IpPacket>;

    /// The name of the TUN device.
    fn name(&self) -> &str;
}
