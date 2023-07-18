use super::InterfaceConfig;
use ip_network::IpNetwork;
use libs_common::{Callbacks, Result};

#[derive(Debug)]
pub(crate) struct IfaceConfig;

impl IfaceConfig {
    #[tracing::instrument(level = "trace", skip(self, _callbacks))]
    pub async fn set_iface_config(
        &mut self,
        _config: &InterfaceConfig,
        _callbacks: &impl Callbacks,
    ) -> Result<()> {
        todo!()
    }

    pub async fn add_route(
        &mut self,
        _route: &IpNetwork,
        _callbacks: &impl Callbacks,
    ) -> Result<()> {
        todo!()
    }

    pub async fn up(&mut self) -> Result<()> {
        todo!()
    }
}
