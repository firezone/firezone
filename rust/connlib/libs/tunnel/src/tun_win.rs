use super::InterfaceConfig;
use ip_network::IpNetwork;
use libs_common::Result;

#[derive(Debug)]
pub(crate) struct IfaceConfig;

impl IfaceConfig {
    // It's easier to not make these functions async, setting these should not block the thread for too long
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_iface_config(&mut self, _config: &InterfaceConfig) -> Result<()> {
        todo!()
    }

    pub async fn up(&mut self) -> Result<()> {
        todo!()
    }

    pub async fn add_route(&mut self, _route: &IpNetwork) -> Result<()> {
        todo!()
    }
}
