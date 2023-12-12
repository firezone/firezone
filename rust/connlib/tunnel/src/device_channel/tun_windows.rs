pub struct Tun {}

impl Tun {
    pub fn new() -> Self {
        Self {}
    }

    pub fn write4(&self, _: &[u8]) -> std::io::Result<usize> {
        Ok(0)
    }

    pub fn write6(&self, _: &[u8]) -> std::io::Result<usize> {
        Ok(0)
    }
}
