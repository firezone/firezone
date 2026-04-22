//! Fixed-size pool of stable worker-slot IDs. `Slot`'s `Drop` returns
//! the ID even on panic or task cancellation, so slots never leak.

use tokio::sync::mpsc;

pub(crate) struct Slot {
    id: usize,
    sender: mpsc::UnboundedSender<usize>,
}

impl std::fmt::Display for Slot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.id.fmt(f)
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        let _ = self.sender.send(self.id);
    }
}

pub(crate) struct SlotPool {
    sender: mpsc::UnboundedSender<usize>,
    receiver: mpsc::UnboundedReceiver<usize>,
}

impl SlotPool {
    pub(crate) fn new(size: usize) -> Self {
        let (sender, receiver) = mpsc::unbounded_channel();
        for i in 0..size {
            let _ = sender.send(i);
        }
        Self { sender, receiver }
    }

    pub(crate) fn try_take(&mut self) -> Option<Slot> {
        let id = self.receiver.try_recv().ok()?;
        Some(Slot {
            id,
            sender: self.sender.clone(),
        })
    }
}
