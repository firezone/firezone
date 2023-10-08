use super::tun::IfaceStream;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct DeviceIo(Arc<IfaceStream>);

impl DeviceIo {
    pub async fn read(&self, out: &mut [u8]) -> std::io::Result<usize> {
        Ok(self.0.read(out).await.unwrap().len())
    }

    pub fn write4(&self, buf: &[u8]) -> std::io::Result<usize> {
        Ok(self.0.write4(buf))
    }

    pub fn write6(&self, buf: &[u8]) -> std::io::Result<usize> {
        Ok(self.0.write6(buf))
    }
}

impl DeviceIo {
    pub fn new(stream: Arc<IfaceStream>) -> DeviceIo {
        DeviceIo(stream)
    }
}
