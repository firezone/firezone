/// The operating system a client simulates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SimulatedOs {
    Linux,
    Android,
    MacOs,
    Ios,
    Windows,
}

impl SimulatedOs {
    /// Returns how long the OS retransmits unacknowledged TCP data before aborting the connection.
    pub fn tcp_timeout(&self) -> l3_tcp::Duration {
        match self {
            // `tcp_retries2 = 15` gives up after ~15 minutes.
            SimulatedOs::Linux | SimulatedOs::Android => l3_tcp::Duration::from_secs(924),
            // `TCP_MAXRXTSHIFT = 12` gives up after ~7.5 minutes.
            SimulatedOs::MacOs | SimulatedOs::Ios => l3_tcp::Duration::from_secs(450),
            // 5 data retransmissions give up within ~90 seconds.
            SimulatedOs::Windows => l3_tcp::Duration::from_secs(90),
        }
    }
}
