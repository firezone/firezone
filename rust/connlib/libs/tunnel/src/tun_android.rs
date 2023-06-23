use super::InterfaceConfig;
use libs_common::Result;

#[derive(Debug)]
pub(crate) struct IfaceConfig(pub(crate) Arc<IfaceDevice>);

#[derive(Debug)]
pub(crate) struct IfaceDevice;

impl IfaceConfig {
    // It's easier to not make these functions async, setting these should not block the thread for too long
    #[tracing::instrument(level = "trace", skip(self))]
    pub fn set_iface_config(&mut self, _config: &InterfaceConfig) -> Result<()> {
        todo!()
    }

    pub fn up(&mut self) -> Result<()> {
        todo!()
    }
}
