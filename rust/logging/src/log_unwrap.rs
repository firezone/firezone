pub trait LogUnwrap {
    fn log_unwrap_debug(&self, msg: &str);
    fn log_unwrap_trace(&self, msg: &str);
}

impl LogUnwrap for anyhow::Result<()> {
    fn log_unwrap_debug(&self, msg: &str) {
        match self {
            Ok(()) => {}
            Err(e) => {
                tracing::debug!("{msg}: {e:#}")
            }
        }
    }

    fn log_unwrap_trace(&self, msg: &str) {
        match self {
            Ok(()) => {}
            Err(e) => {
                tracing::trace!("{msg}: {e:#}")
            }
        }
    }
}
