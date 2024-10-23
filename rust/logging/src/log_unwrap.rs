use std::error::Error;

pub trait LogUnwrap {
    #[track_caller]
    fn log_unwrap_warn(&self, msg: &str);
    #[track_caller]
    fn log_unwrap_debug(&self, msg: &str);
    #[track_caller]
    fn log_unwrap_trace(&self, msg: &str);
}

impl LogUnwrap for anyhow::Result<()> {
    #[track_caller]
    fn log_unwrap_warn(&self, msg: &str) {
        match self {
            Ok(()) => {}
            Err(e) => {
                let error: &dyn Error = e.as_ref();

                tracing::warn!(error, "{msg}")
            }
        }
    }

    #[track_caller]
    fn log_unwrap_debug(&self, msg: &str) {
        match self {
            Ok(()) => {}
            Err(e) => {
                let error: &dyn Error = e.as_ref();

                tracing::debug!(error, "{msg}")
            }
        }
    }

    #[track_caller]
    fn log_unwrap_trace(&self, msg: &str) {
        match self {
            Ok(()) => {}
            Err(e) => {
                let error: &dyn Error = e.as_ref();

                tracing::trace!(error, "{msg}")
            }
        }
    }
}
