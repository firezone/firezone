//! TOML configuration for randomized load testing.
//!
//! All config fields are required - see loadtest.example.toml for defaults.
//! Each invocation randomly selects a test type and parameters from the config.

/// Minimum ping count (must send at least 1 ping).
pub const MIN_PING_COUNT: usize = 1;

use rand::SeedableRng;
use rand::prelude::*;
use rand::rngs::StdRng;
use serde::Deserialize;
use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::time::Duration;
use url::Url;

use crate::ping::MAX_ICMP_PAYLOAD_SIZE;

/// Top-level configuration loaded from TOML.
#[derive(Debug, Deserialize)]
pub struct LoadTestConfig {
    /// Test types to run. Must be non-empty.
    pub types: Vec<TestType>,
    pub http: HttpConfig,
    pub tcp: TcpConfig,
    pub websocket: WebsocketConfig,
    pub ping: PingConfig,
}

/// A numeric range with optional step constraint.
///
/// If `step` is specified, valid values are `[min, min+step, min+2*step, ...]` up to `max`.
/// If `step` is omitted, any integer in `[min, max]` is valid.
#[derive(Debug, Clone, Deserialize)]
pub struct Range {
    pub min: u64,
    pub max: u64,
    pub step: Option<u64>,
}

impl Range {
    /// Validate the range configuration.
    pub fn validate(&self, field_name: &str, section: &str) -> Result<(), ConfigError> {
        if self.min > self.max {
            return Err(ConfigError::InvalidRange {
                section: section.to_string(),
                field: field_name.to_string(),
                min: self.min,
                max: self.max,
            });
        }

        if let Some(step) = self.step
            && step == 0
        {
            return Err(ConfigError::ZeroStep {
                section: section.to_string(),
                field: field_name.to_string(),
            });
        }

        Ok(())
    }

    /// Pick a random value from the range.
    pub fn pick<R: Rng>(&self, rng: &mut R) -> u64 {
        match self.step {
            Some(step) => {
                let num_steps = (self.max - self.min) / step;
                let chosen_step = rng.gen_range(0..=num_steps);
                self.min + chosen_step * step
            }
            None => rng.gen_range(self.min..=self.max),
        }
    }
}

/// HTTP load test configuration.
#[derive(Debug, Deserialize)]
pub struct HttpConfig {
    /// List of target URLs to choose from.
    pub addresses: Vec<String>,
    /// HTTP versions to choose from (1 or 2).
    pub http_version: Vec<u8>,
    /// Number of concurrent users.
    pub users: Range,
    /// Test duration in seconds.
    pub run_time_secs: Range,
}

impl HttpConfig {
    fn validate(&self) -> Result<(), ConfigError> {
        if self.addresses.is_empty() {
            return Err(ConfigError::EmptyAddresses {
                section: "http".to_string(),
            });
        }

        // Validate all URLs can be parsed
        for addr in &self.addresses {
            Url::parse(addr).map_err(|e| ConfigError::InvalidUrl {
                section: "http".to_string(),
                url: addr.clone(),
                error: e.to_string(),
            })?;
        }

        if self.http_version.is_empty() {
            return Err(ConfigError::EmptyHttpVersions);
        }
        for v in &self.http_version {
            if *v != 1 && *v != 2 {
                return Err(ConfigError::InvalidHttpVersion { version: *v });
            }
        }

        self.users.validate("users", "http")?;
        self.run_time_secs.validate("run_time_secs", "http")?;

        Ok(())
    }
}

/// TCP load test configuration.
#[derive(Debug, Deserialize)]
pub struct TcpConfig {
    /// List of target addresses (host:port) to choose from.
    pub addresses: Vec<String>,
    /// Number of concurrent connections.
    pub concurrent: Range,
    /// How long to hold connections in seconds.
    pub duration_secs: Range,
    /// Connection timeout in seconds.
    pub timeout_secs: Range,
    /// Enable echo mode for payload verification.
    pub echo_mode: bool,
    /// Echo payload size in bytes.
    pub echo_payload_size: Range,
    /// Interval between echo messages in seconds.
    pub echo_interval_secs: Range,
    /// Timeout for reading echo responses in seconds.
    pub echo_read_timeout_secs: Range,
}

impl TcpConfig {
    fn validate(&self) -> Result<(), ConfigError> {
        if self.addresses.is_empty() {
            return Err(ConfigError::EmptyAddresses {
                section: "tcp".to_string(),
            });
        }

        // Validate all addresses can be parsed
        for addr in &self.addresses {
            addr.parse::<SocketAddr>()
                .map_err(|e| ConfigError::InvalidSocketAddr {
                    section: "tcp".to_string(),
                    addr: addr.clone(),
                    error: e.to_string(),
                })?;
        }

        self.concurrent.validate("concurrent", "tcp")?;
        self.duration_secs.validate("duration_secs", "tcp")?;
        self.timeout_secs.validate("timeout_secs", "tcp")?;
        self.echo_payload_size
            .validate("echo_payload_size", "tcp")?;
        self.echo_interval_secs
            .validate("echo_interval_secs", "tcp")?;
        self.echo_read_timeout_secs
            .validate("echo_read_timeout_secs", "tcp")?;

        Ok(())
    }
}

/// WebSocket load test configuration.
#[derive(Debug, Deserialize)]
pub struct WebsocketConfig {
    /// List of WebSocket URLs to choose from.
    pub addresses: Vec<String>,
    /// Number of concurrent connections.
    pub concurrent: Range,
    /// How long to hold connections in seconds.
    pub duration_secs: Range,
    /// Connection timeout in seconds.
    pub timeout_secs: Range,
    /// Ping interval in seconds. Ignored in echo mode.
    pub ping_interval_secs: Range,
    /// Enable echo mode for payload verification.
    pub echo_mode: bool,
    /// Echo payload size in bytes.
    pub echo_payload_size: Range,
    /// Interval between echo messages in seconds.
    pub echo_interval_secs: Range,
    /// Timeout for reading echo responses in seconds.
    pub echo_read_timeout_secs: Range,
}

impl WebsocketConfig {
    fn validate(&self) -> Result<(), ConfigError> {
        if self.addresses.is_empty() {
            return Err(ConfigError::EmptyAddresses {
                section: "websocket".to_string(),
            });
        }

        // Validate all URLs can be parsed
        for addr in &self.addresses {
            Url::parse(addr).map_err(|e| ConfigError::InvalidUrl {
                section: "websocket".to_string(),
                url: addr.clone(),
                error: e.to_string(),
            })?;
        }

        self.concurrent.validate("concurrent", "websocket")?;
        self.duration_secs.validate("duration_secs", "websocket")?;
        self.timeout_secs.validate("timeout_secs", "websocket")?;
        self.ping_interval_secs
            .validate("ping_interval_secs", "websocket")?;
        self.echo_payload_size
            .validate("echo_payload_size", "websocket")?;
        self.echo_interval_secs
            .validate("echo_interval_secs", "websocket")?;
        self.echo_read_timeout_secs
            .validate("echo_read_timeout_secs", "websocket")?;

        Ok(())
    }
}

/// ICMP ping load test configuration.
#[derive(Debug, Deserialize)]
pub struct PingConfig {
    /// List of target IP addresses to ping.
    pub addresses: Vec<String>,
    /// Number of pings per target.
    pub count: Range,
    /// Interval between pings in milliseconds.
    pub interval_ms: Range,
    /// Ping timeout in milliseconds.
    pub timeout_ms: Range,
    /// Payload size in bytes.
    pub payload_size: Range,
}

impl PingConfig {
    fn validate(&self) -> Result<(), ConfigError> {
        if self.addresses.is_empty() {
            return Err(ConfigError::EmptyAddresses {
                section: "ping".to_string(),
            });
        }

        // Validate all addresses are valid IP addresses
        for addr in &self.addresses {
            addr.parse::<IpAddr>()
                .map_err(|e| ConfigError::InvalidIpAddr {
                    section: "ping".to_string(),
                    addr: addr.clone(),
                    error: e.to_string(),
                })?;
        }

        self.count.validate("count", "ping")?;
        self.interval_ms.validate("interval_ms", "ping")?;
        self.timeout_ms.validate("timeout_ms", "ping")?;
        self.payload_size.validate("payload_size", "ping")?;
        if self.payload_size.max as usize > MAX_ICMP_PAYLOAD_SIZE {
            return Err(ConfigError::PayloadSizeTooLarge {
                size: self.payload_size.max,
                max: MAX_ICMP_PAYLOAD_SIZE,
            });
        }

        Ok(())
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("Failed to read config file: {0}")]
    ReadError(#[from] std::io::Error),

    #[error("Failed to parse TOML: {0}")]
    ParseError(#[from] toml::de::Error),

    #[error("'types' list cannot be empty")]
    NoTestTypes,

    #[error("[{section}] addresses list is empty")]
    EmptyAddresses { section: String },

    #[error("[{section}] invalid URL '{url}': {error}")]
    InvalidUrl {
        section: String,
        url: String,
        error: String,
    },

    #[error("[{section}] invalid address '{addr}': {error}")]
    InvalidSocketAddr {
        section: String,
        addr: String,
        error: String,
    },

    #[error("[{section}] invalid IP address '{addr}': {error}")]
    InvalidIpAddr {
        section: String,
        addr: String,
        error: String,
    },

    #[error("[{section}] {field}.min ({min}) is greater than {field}.max ({max})")]
    InvalidRange {
        section: String,
        field: String,
        min: u64,
        max: u64,
    },

    #[error("[{section}] {field}.step cannot be zero")]
    ZeroStep { section: String, field: String },

    #[error("Invalid HTTP version: {version}. Must be 1 or 2.")]
    InvalidHttpVersion { version: u8 },

    #[error("http_version list cannot be empty")]
    EmptyHttpVersions,

    #[error("[ping] payload_size.max ({size}) exceeds maximum ICMP payload of {max} bytes")]
    PayloadSizeTooLarge { size: u64, max: usize },
}

impl LoadTestConfig {
    /// Load and validate configuration from a TOML file.
    pub fn load(path: &Path) -> Result<Self, ConfigError> {
        let contents = std::fs::read_to_string(path)?;
        let config: LoadTestConfig = toml::from_str(&contents)?;
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> Result<(), ConfigError> {
        // Validate types field
        if self.types.is_empty() {
            return Err(ConfigError::NoTestTypes);
        }

        // Validate all sections
        self.http.validate()?;
        self.tcp.validate()?;
        self.websocket.validate()?;
        self.ping.validate()?;

        Ok(())
    }

    pub fn enabled_types(&self) -> &[TestType] {
        &self.types
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TestType {
    Http,
    Tcp,
    Websocket,
    Ping,
}

impl std::fmt::Display for TestType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Http => write!(f, "http"),
            Self::Tcp => write!(f, "tcp"),
            Self::Websocket => write!(f, "websocket"),
            Self::Ping => write!(f, "ping"),
        }
    }
}

/// Resolved HTTP test parameters (ready to execute).
#[derive(Debug)]
pub struct ResolvedHttpConfig {
    pub address: Url,
    pub http_version: u8,
    pub users: u64,
    pub run_time: Duration,
}

/// Resolved TCP test parameters (ready to execute).
#[derive(Debug)]
pub struct ResolvedTcpConfig {
    pub address: SocketAddr,
    pub concurrent: usize,
    pub duration: Duration,
    pub timeout: Duration,
    pub echo_mode: bool,
    pub echo_payload_size: usize,
    pub echo_interval: Option<Duration>,
    pub echo_read_timeout: Duration,
}

/// Resolved WebSocket test parameters (ready to execute).
#[derive(Debug)]
pub struct ResolvedWebsocketConfig {
    pub address: Url,
    pub concurrent: usize,
    pub duration: Duration,
    pub timeout: Duration,
    pub ping_interval: Option<Duration>,
    pub echo_mode: bool,
    pub echo_payload_size: usize,
    pub echo_interval: Option<Duration>,
    pub echo_read_timeout: Duration,
}

/// Resolved ping test parameters (ready to execute).
#[derive(Debug)]
pub struct ResolvedPingConfig {
    /// Target IP addresses.
    pub targets: Vec<IpAddr>,
    /// Number of pings per target.
    pub count: usize,
    /// Interval between pings.
    pub interval: Duration,
    /// Ping timeout.
    pub timeout: Duration,
    /// Payload size.
    pub payload_size: usize,
}

/// Resolved test configuration (one of the test types).
#[derive(Debug)]
pub enum ResolvedConfig {
    Http(ResolvedHttpConfig),
    Tcp(ResolvedTcpConfig),
    Websocket(ResolvedWebsocketConfig),
    Ping(ResolvedPingConfig),
}

/// Random test selector.
pub struct TestSelector {
    rng: StdRng,
    seed: u64,
}

impl TestSelector {
    /// Create a new selector with the given seed, or generate a random one.
    pub fn new(seed: Option<u64>) -> Self {
        let seed = seed.unwrap_or_else(rand::random);
        let rng = StdRng::seed_from_u64(seed);
        Self { rng, seed }
    }

    pub fn seed(&self) -> u64 {
        self.seed
    }

    pub fn select(&mut self, config: &LoadTestConfig) -> ResolvedConfig {
        let types = config.enabled_types();
        let test_type = types[self.rng.gen_range(0..types.len())];

        match test_type {
            TestType::Http => ResolvedConfig::Http(self.resolve_http(&config.http)),
            TestType::Tcp => ResolvedConfig::Tcp(self.resolve_tcp(&config.tcp)),
            TestType::Websocket => {
                ResolvedConfig::Websocket(self.resolve_websocket(&config.websocket))
            }
            TestType::Ping => ResolvedConfig::Ping(self.resolve_ping(&config.ping)),
        }
    }

    fn resolve_http(&mut self, config: &HttpConfig) -> ResolvedHttpConfig {
        let addr_str = &config.addresses[self.rng.gen_range(0..config.addresses.len())];
        let address = Url::parse(addr_str).expect("URL validated during config load");
        let http_version = config.http_version[self.rng.gen_range(0..config.http_version.len())];
        let users = config.users.pick(&mut self.rng);
        let run_time = Duration::from_secs(config.run_time_secs.pick(&mut self.rng));

        ResolvedHttpConfig {
            address,
            http_version,
            users,
            run_time,
        }
    }

    fn resolve_tcp(&mut self, config: &TcpConfig) -> ResolvedTcpConfig {
        let addr_str = &config.addresses[self.rng.gen_range(0..config.addresses.len())];
        let address: SocketAddr = addr_str
            .parse()
            .expect("Address validated during config load");

        let concurrent = config.concurrent.pick(&mut self.rng) as usize;
        let duration = Duration::from_secs(config.duration_secs.pick(&mut self.rng));
        let timeout = Duration::from_secs(config.timeout_secs.pick(&mut self.rng));
        let echo_mode = config.echo_mode;
        let echo_payload_size = config.echo_payload_size.pick(&mut self.rng) as usize;
        let echo_interval = Some(Duration::from_secs(
            config.echo_interval_secs.pick(&mut self.rng),
        ));
        let echo_read_timeout =
            Duration::from_secs(config.echo_read_timeout_secs.pick(&mut self.rng));

        ResolvedTcpConfig {
            address,
            concurrent,
            duration,
            timeout,
            echo_mode,
            echo_payload_size,
            echo_interval,
            echo_read_timeout,
        }
    }

    fn resolve_websocket(&mut self, config: &WebsocketConfig) -> ResolvedWebsocketConfig {
        let addr_str = &config.addresses[self.rng.gen_range(0..config.addresses.len())];
        let address = Url::parse(addr_str).expect("URL validated during config load");

        let concurrent = config.concurrent.pick(&mut self.rng) as usize;
        let duration = Duration::from_secs(config.duration_secs.pick(&mut self.rng));
        let timeout = Duration::from_secs(config.timeout_secs.pick(&mut self.rng));
        let ping_interval = Some(Duration::from_secs(
            config.ping_interval_secs.pick(&mut self.rng),
        ));
        let echo_mode = config.echo_mode;
        let echo_payload_size = config.echo_payload_size.pick(&mut self.rng) as usize;
        let echo_interval = Some(Duration::from_secs(
            config.echo_interval_secs.pick(&mut self.rng),
        ));
        let echo_read_timeout =
            Duration::from_secs(config.echo_read_timeout_secs.pick(&mut self.rng));

        ResolvedWebsocketConfig {
            address,
            concurrent,
            duration,
            timeout,
            ping_interval,
            echo_mode,
            echo_payload_size,
            echo_interval,
            echo_read_timeout,
        }
    }

    fn resolve_ping(&mut self, config: &PingConfig) -> ResolvedPingConfig {
        // Parse all targets
        let targets: Vec<IpAddr> = config
            .addresses
            .iter()
            .map(|s| s.parse().expect("IP address validated during config load"))
            .collect();

        // Ensure minimum count of 1 ping
        let count = (config.count.pick(&mut self.rng) as usize).max(MIN_PING_COUNT);
        let interval = Duration::from_millis(config.interval_ms.pick(&mut self.rng));
        let timeout = Duration::from_millis(config.timeout_ms.pick(&mut self.rng));
        let payload_size = config.payload_size.pick(&mut self.rng) as usize;

        ResolvedPingConfig {
            targets,
            count,
            interval,
            timeout,
            payload_size,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Returns the content of loadtest.example.toml with arrays normalized to single-line.
    fn example_config_content() -> String {
        normalize_toml_arrays(include_str!("../loadtest.example.toml"))
    }

    /// Collapse multiline TOML arrays into single-line format for easier test replacements.
    fn normalize_toml_arrays(s: &str) -> String {
        let mut result = String::with_capacity(s.len());
        let mut in_array = false;
        let mut array_content = String::new();

        for line in s.lines() {
            let trimmed = line.trim();

            if !in_array {
                if let Some(pos) = line.find("= [") {
                    if trimmed.ends_with(']') {
                        // Already single-line array
                        result.push_str(line);
                        result.push('\n');
                    } else {
                        // Start of multiline array
                        in_array = true;
                        array_content = line[..pos + 3].to_string(); // "key = ["
                    }
                } else {
                    result.push_str(line);
                    result.push('\n');
                }
            } else if trimmed == "]" {
                // End of multiline array
                if array_content.ends_with(", ") {
                    array_content.truncate(array_content.len() - 2);
                }
                array_content.push(']');
                result.push_str(&array_content);
                result.push('\n');
                array_content.clear();
                in_array = false;
            } else if !trimmed.is_empty() {
                // Array element
                let element = trimmed.trim_end_matches(',');
                if !array_content.ends_with('[') {
                    array_content.push_str(", ");
                }
                array_content.push_str(element);
            }
        }

        result
    }

    #[test]
    fn test_range_pick_single_value() {
        let range = Range {
            min: 5,
            max: 5,
            step: None,
        };
        let mut rng = StdRng::seed_from_u64(42);
        // When min == max, the only possible value is that value
        assert_eq!(range.pick(&mut rng), 5);
    }

    #[test]
    fn test_range_pick_without_step() {
        let range = Range {
            min: 10,
            max: 20,
            step: None,
        };
        let mut rng = StdRng::seed_from_u64(42);
        // Should produce values in the range [10, 20]
        for _ in 0..100 {
            let value = range.pick(&mut rng);
            assert!((10..=20).contains(&value), "Value {value} out of range");
        }
    }

    #[test]
    fn test_range_pick_with_step() {
        let range = Range {
            min: 10,
            max: 30,
            step: Some(10),
        };
        let mut rng = StdRng::seed_from_u64(42);
        // Should only produce 10, 20, or 30
        for _ in 0..100 {
            let value = range.pick(&mut rng);
            assert!(
                value == 10 || value == 20 || value == 30,
                "Value {value} not a valid step"
            );
        }
    }

    #[test]
    fn test_range_pick_step_larger_than_range() {
        let range = Range {
            min: 5,
            max: 8,
            step: Some(10),
        };
        let mut rng = StdRng::seed_from_u64(42);
        // When step > (max - min), only min is valid
        assert_eq!(range.pick(&mut rng), 5);
    }

    #[test]
    fn test_range_validate_min_greater_than_max() {
        let range = Range {
            min: 20,
            max: 10,
            step: None,
        };
        let result = range.validate("test_field", "test_section");
        assert!(matches!(result, Err(ConfigError::InvalidRange { .. })));
    }

    #[test]
    fn test_range_validate_zero_step() {
        let range = Range {
            min: 10,
            max: 20,
            step: Some(0),
        };
        let result = range.validate("test_field", "test_section");
        assert!(matches!(result, Err(ConfigError::ZeroStep { .. })));
    }

    #[test]
    fn test_range_validate_success() {
        let range = Range {
            min: 10,
            max: 100,
            step: Some(10),
        };
        let result = range.validate("test_field", "test_section");
        assert!(result.is_ok());
    }

    #[test]
    fn test_load_missing_file() {
        let result = LoadTestConfig::load(Path::new("/nonexistent/config.toml"));
        assert!(matches!(result, Err(ConfigError::ReadError(_))));
    }

    #[test]
    fn test_load_invalid_toml() {
        let dir = std::env::temp_dir();
        let path = dir.join("invalid_config.toml");
        std::fs::write(&path, "this is not valid { toml").unwrap();

        let result = LoadTestConfig::load(&path);
        assert!(matches!(result, Err(ConfigError::ParseError(_))));

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_missing_required_fields() {
        let dir = std::env::temp_dir();
        let path = dir.join("no_types_config.toml");
        // Config missing required 'types' field - should fail to parse
        std::fs::write(&path, "# Empty config\n").unwrap();

        let result = LoadTestConfig::load(&path);
        assert!(matches!(result, Err(ConfigError::ParseError(_))));

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_explicit_empty_types() {
        let dir = std::env::temp_dir();
        let path = dir.join("explicit_empty_types_config.toml");
        // Empty types array should fail validation
        let config = example_config_content().replace(r#"types = ["http"]"#, "types = []");
        std::fs::write(&path, &config).unwrap();

        let result = LoadTestConfig::load(&path);
        assert!(matches!(result, Err(ConfigError::NoTestTypes)));

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_empty_addresses() {
        let dir = std::env::temp_dir();
        let path = dir.join("empty_addresses_config.toml");
        let config = example_config_content()
            .replace(r#"addresses = ["https://example.com"]"#, "addresses = []");
        std::fs::write(&path, &config).unwrap();

        let result = LoadTestConfig::load(&path);
        assert!(
            matches!(result, Err(ConfigError::EmptyAddresses { section }) if section == "http")
        );

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_invalid_url() {
        let dir = std::env::temp_dir();
        let path = dir.join("invalid_url_config.toml");
        let config = example_config_content().replace(
            r#"addresses = ["https://example.com"]"#,
            r#"addresses = ["not a valid url"]"#,
        );
        std::fs::write(&path, &config).unwrap();

        let result = LoadTestConfig::load(&path);
        assert!(
            matches!(result, Err(ConfigError::InvalidUrl { section, .. }) if section == "http")
        );

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_invalid_socket_addr() {
        let dir = std::env::temp_dir();
        let path = dir.join("invalid_socket_config.toml");
        let config = example_config_content().replace(
            r#"addresses = ["127.0.0.1:8080"]"#,
            r#"addresses = ["not:a:valid:addr"]"#,
        );
        std::fs::write(&path, &config).unwrap();

        let result = LoadTestConfig::load(&path);
        assert!(
            matches!(result, Err(ConfigError::InvalidSocketAddr { section, .. }) if section == "tcp")
        );

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_invalid_ip_addr() {
        let dir = std::env::temp_dir();
        let path = dir.join("invalid_ip_config.toml");
        let config = example_config_content().replace(
            r#"addresses = ["8.8.8.8", "1.1.1.1"]"#,
            r#"addresses = ["not.an.ip"]"#,
        );
        std::fs::write(&path, &config).unwrap();

        let result = LoadTestConfig::load(&path);
        assert!(
            matches!(result, Err(ConfigError::InvalidIpAddr { section, .. }) if section == "ping")
        );

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_invalid_http_version() {
        let dir = std::env::temp_dir();
        let path = dir.join("invalid_http_version_config.toml");
        let config =
            example_config_content().replace("http_version = [1, 2]", "http_version = [3]");
        std::fs::write(&path, &config).unwrap();

        let result = LoadTestConfig::load(&path);
        assert!(matches!(
            result,
            Err(ConfigError::InvalidHttpVersion { version: 3 })
        ));

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_empty_http_versions() {
        let dir = std::env::temp_dir();
        let path = dir.join("empty_http_versions_config.toml");
        let config = example_config_content().replace("http_version = [1, 2]", "http_version = []");
        std::fs::write(&path, &config).unwrap();

        let result = LoadTestConfig::load(&path);
        assert!(matches!(result, Err(ConfigError::EmptyHttpVersions)));

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_valid_config() {
        let dir = std::env::temp_dir();
        let path = dir.join("valid_config.toml");
        let config =
            example_config_content().replace(r#"types = ["http"]"#, r#"types = ["http", "tcp"]"#);
        std::fs::write(&path, &config).unwrap();

        let result = LoadTestConfig::load(&path);
        assert!(result.is_ok());

        let config = result.unwrap();
        assert_eq!(config.enabled_types(), &[TestType::Http, TestType::Tcp]);

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_ping_payload_too_large() {
        let dir = std::env::temp_dir();
        let path = dir.join("ping_payload_too_large_config.toml");
        let config = example_config_content().replace(
            "payload_size = { min = 56, max = 1024 }",
            "payload_size = { min = 56, max = 100000 }",
        );
        std::fs::write(&path, &config).unwrap();

        let result = LoadTestConfig::load(&path);
        assert!(matches!(
            result,
            Err(ConfigError::PayloadSizeTooLarge { size: 100000, .. })
        ));

        std::fs::remove_file(&path).ok();
    }
}
