use std::time::Instant;

#[derive(Debug)]
pub struct ConnectionInfo {
    /// When this instance of [`ConnectionInfo`] was created.
    pub generated_at: Instant,
}
