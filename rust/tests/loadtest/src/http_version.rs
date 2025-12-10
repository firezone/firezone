//! HTTP version configuration for load testing.

use clap::ValueEnum;
use std::time::Duration;

/// HTTP protocol version to use for load testing.
#[derive(Debug, Clone, Copy, ValueEnum, Default, PartialEq, Eq)]
pub enum HttpVersion {
    /// HTTP/1.1 - widely supported, connection-per-request
    #[default]
    #[value(name = "1", alias = "1.1", alias = "http1")]
    Http1,

    /// HTTP/2 - multiplexed streams, header compression
    #[value(name = "2", alias = "http2")]
    Http2,
}

impl HttpVersion {
    /// Configure a reqwest `ClientBuilder` for this HTTP version.
    pub fn configure_client(self, timeout: Duration) -> reqwest::ClientBuilder {
        let builder = reqwest::ClientBuilder::new()
            .timeout(timeout)
            .gzip(true)
            .cookie_store(true);

        match self {
            Self::Http1 => builder.http1_only(),
            Self::Http2 => builder.http2_prior_knowledge(),
        }
    }

    /// Returns display name for metrics output.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Http1 => "HTTP/1.1",
            Self::Http2 => "HTTP/2",
        }
    }
}

impl std::fmt::Display for HttpVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}
