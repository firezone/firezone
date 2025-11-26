#[derive(Debug, Clone)]
#[cfg_attr(
    target_os = "linux",
    expect(dead_code, reason = "Power events are not yet implemented on Linux.")
)]
pub enum PowerEvent {
    Suspend,
    Resume,
}

pub type Sender = tokio::sync::mpsc::Sender<PowerEvent>;
pub type Receiver = tokio::sync::mpsc::Receiver<PowerEvent>;

pub fn channel() -> (Sender, Receiver) {
    tokio::sync::mpsc::channel(10)
}
