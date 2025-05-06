use std::sync::Arc;

use parking_lot::{Mutex, MutexGuard};
use tracing_subscriber::fmt::MakeWriter;

#[derive(Debug, Default, Clone)]
pub struct CapturingWriter {
    content: Arc<Mutex<String>>,
}

impl std::io::Write for CapturingWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let line = std::str::from_utf8(buf).map_err(std::io::Error::other)?;
        self.content.lock().push_str(line);

        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl CapturingWriter {
    pub fn lines(&self) -> MutexGuard<'_, String> {
        self.content.lock()
    }
}

impl<'a> MakeWriter<'a> for CapturingWriter {
    type Writer = Self;

    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}
