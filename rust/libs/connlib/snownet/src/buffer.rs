use std::collections::VecDeque;

use crate::crypto::{EncryptJob, Encryptor};
use crate::node::Transmit;

/// Collects datagrams as standalone [`Transmit`]s.
pub struct TransmitBuffer {
    transmits: VecDeque<Transmit>,
}

impl TransmitBuffer {
    pub fn new() -> Self {
        Self {
            transmits: VecDeque::default(),
        }
    }

    /// Collect an already-formed [`Transmit`].
    ///
    /// Used for datagrams that were produced elsewhere as a standalone [`Transmit`], e.g. a
    /// handshake that cannot be encrypted in place because there is no session yet.
    pub fn push(&mut self, transmit: Transmit) {
        self.transmits.push_back(transmit);
    }

    /// Returns the next collected [`Transmit`], if any.
    pub fn poll_transmit(&mut self) -> Option<Transmit> {
        self.transmits.pop_front()
    }

    pub fn is_empty(&self) -> bool {
        self.transmits.is_empty()
    }

    pub fn clear(&mut self) {
        self.transmits.clear();
    }
}

impl Extend<Transmit> for TransmitBuffer {
    fn extend<T: IntoIterator<Item = Transmit>>(&mut self, iter: T) {
        self.transmits.extend(iter);
    }
}

impl Default for TransmitBuffer {
    fn default() -> Self {
        Self::new()
    }
}

impl Encryptor for TransmitBuffer {
    fn encrypt(&mut self, job: EncryptJob) {
        match job.encrypt() {
            Ok(transmit) => self.transmits.push_back(transmit),
            Err(e) => tracing::debug!("Failed to encrypt packet: {e}"),
        }
    }
}
