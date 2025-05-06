use std::sync::{Arc, Mutex, MutexGuard};

use tracing_subscriber::fmt::MakeWriter;

#[derive(Debug, Default, Clone)]
pub struct CapturingWriter {
    lines: Arc<Mutex<Vec<String>>>,
}

impl std::io::Write for CapturingWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let line = String::from_utf8_lossy(buf).to_string();
        self.lines
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(line);

        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl CapturingWriter {
    pub fn lines(&self) -> MutexGuard<'_, Vec<String>> {
        self.lines.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl<'a> MakeWriter<'a> for CapturingWriter {
    type Writer = Self;

    fn make_writer(&'a self) -> Self::Writer {
        CapturingWriter::default()
    }
}
