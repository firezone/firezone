use crate::device_channel::create_iface;
use crate::{ControlSignal, Device, GatewayState, Tunnel, MAX_UDP_SIZE};
use connlib_shared::messages::Interface as InterfaceConfig;
use connlib_shared::Callbacks;
use std::sync::Arc;

impl<C, CB> Tunnel<C, CB, GatewayState>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_interface(
        self: &Arc<Self>,
        config: &InterfaceConfig,
    ) -> connlib_shared::Result<()> {
        let device = create_iface(config, self.callbacks()).await?;
        *self.device.write().await = Some(device.clone());

        self.start_timers().await?;
        self.start_device(device);

        tracing::debug!("background_loop_started");

        Ok(())
    }

    fn start_device(self: &Arc<Self>, mut device: Device) {
        let tunnel = Arc::clone(self);

        *self.iface_handler_abort.lock() = Some(
            tokio::spawn(async move {
                let mut buf = [0u8; MAX_UDP_SIZE];
                loop {
                    let Some(packet) = device.read().await? else {
                        // Reading a bad IP packet or otherwise from the device seems bad. Should we restart the tunnel or something?
                        return connlib_shared::Result::Ok(());
                    };

                    let dest = packet.destination();

                    let Some(peer) = tunnel.peer_by_ip(dest) else {
                        continue;
                    };

                    if let Err(e) = tunnel
                        .encapsulate_and_send_to_peer(packet, peer, &dest, &mut buf)
                        .await
                    {
                        tracing::error!(err = ?e, "failed to handle packet {e:#}")
                    }
                }
            })
            .abort_handle(),
        );
    }
}
