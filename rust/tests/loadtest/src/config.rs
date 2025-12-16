//! TOML configuration for randomized load testing.
//!
//! All config fields are required - see loadtest.example.toml for defaults.
//! Each invocation randomly selects a test type and parameters from the config.

/// Minimum ping count (must send at least 1 ping).
pub const MIN_PING_COUNT: usize = 1;

use anyhow::{Context as _, Result, bail};
use rand::distributions::uniform::SampleRange;
use rand::prelude::*;
use serde::Deserialize;
use std::net::IpAddr;
use std::path::Path;
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
#[derive(Debug, Clone, Copy)]
pub struct Range {
    pub min: u64,
    pub max: u64,
}

impl<'de> serde::Deserialize<'de> for Range {
    fn deserialize<D>(d: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        use serde::de::Error as _;

        let string = String::deserialize(d)?;
        let parts = string.split("..").collect::<Vec<&str>>();

        if parts.len() != 2 {
            return Err(D::Error::custom(format!(
                "Range must be in format 'min..max', got: '{}'",
                string
            )));
        }

        let start = parts[0]
            .parse::<u64>()
            .map_err(|e| D::Error::custom(format!("Invalid start value '{}': {}", parts[0], e)))?;

        let end = parts[1]
            .parse::<u64>()
            .map_err(|e| D::Error::custom(format!("Invalid end value '{}': {}", parts[1], e)))?;

        if end < start {
            return Err(D::Error::custom("end must be greater or equal to start"));
        }

        Ok(Self {
            min: start,
            max: end,
        })
    }
}

impl SampleRange<u64> for Range {
    fn sample_single<R: RngCore + ?Sized>(self, rng: &mut R) -> u64 {
        rng.gen_range(std::ops::RangeInclusive::new(self.min, self.max))
    }

    fn is_empty(&self) -> bool {
        self.max - self.min == 0
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
    fn validate(&self) -> Result<()> {
        if self.addresses.is_empty() {
            bail!("[http] addresses list is empty");
        }

        // Validate all URLs can be parsed
        for addr in &self.addresses {
            Url::parse(addr).with_context(|| format!("[http] invalid URL '{addr}'"))?;
        }

        if self.http_version.is_empty() {
            bail!("http_version list cannot be empty");
        }
        for v in &self.http_version {
            if *v != 1 && *v != 2 {
                bail!("Invalid HTTP version: {v}. Must be 1 or 2.");
            }
        }

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
    fn validate(&self) -> Result<()> {
        if self.addresses.is_empty() {
            bail!("[tcp] addresses list is empty");
        }

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
    fn validate(&self) -> Result<()> {
        if self.addresses.is_empty() {
            bail!("[websocket] addresses list is empty");
        }

        // Validate all URLs can be parsed
        for addr in &self.addresses {
            Url::parse(addr).with_context(|| format!("[websocket] invalid URL '{addr}'"))?;
        }

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
    fn validate(&self) -> Result<()> {
        if self.addresses.is_empty() {
            bail!("[ping] addresses list is empty");
        }

        // Validate all addresses are valid IP addresses
        for addr in &self.addresses {
            addr.parse::<IpAddr>()
                .with_context(|| format!("[ping] invalid IP address '{addr}'"))?;
        }

        if self.payload_size.max as usize > MAX_ICMP_PAYLOAD_SIZE {
            bail!(
                "[ping] payload_size.max ({}) exceeds maximum ICMP payload of {} bytes",
                self.payload_size.max,
                MAX_ICMP_PAYLOAD_SIZE
            );
        }

        Ok(())
    }
}

impl LoadTestConfig {
    /// Load and validate configuration from a TOML file.
    pub fn load(path: &Path) -> Result<Self> {
        let contents = std::fs::read_to_string(path).context("Failed to read config file")?;
        let config: LoadTestConfig = toml::from_str(&contents).context("Failed to parse TOML")?;
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> Result<()> {
        // Validate types field
        if self.types.is_empty() {
            bail!("'types' list cannot be empty");
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
    fn test_load_missing_file() {
        let result = LoadTestConfig::load(Path::new("/nonexistent/config.toml"));

        #[cfg(unix)]
        assert_eq!(
            format!("{:#}", result.unwrap_err()),
            "Failed to read config file: No such file or directory (os error 2)"
        );
        #[cfg(windows)]
        assert_eq!(
            format!("{:#}", result.unwrap_err()),
            "Failed to read config file: The system cannot find the path specified. (os error 3)"
        );
    }

    #[test]
    fn test_load_invalid_toml() {
        let dir = std::env::temp_dir();
        let path = dir.join("invalid_config.toml");
        std::fs::write(&path, "this is not valid { toml").unwrap();

        let result = LoadTestConfig::load(&path);
        assert_eq!(
            format!("{:#}", result.unwrap_err()),
            "Failed to parse TOML: TOML parse error at line 1, column 6\n  |\n1 | this is not valid { toml\n  |      ^\nkey with no value, expected `=`\n"
        );

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_missing_required_fields() {
        let dir = std::env::temp_dir();
        let path = dir.join("no_types_config.toml");
        // Config missing required 'types' field - should fail to parse
        std::fs::write(&path, "# Empty config\n").unwrap();

        let result = LoadTestConfig::load(&path);
        assert_eq!(
            format!("{:#}", result.unwrap_err()),
            "Failed to parse TOML: TOML parse error at line 1, column 1\n  |\n1 | # Empty config\n  | ^\nmissing field `types`\n"
        );

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
        assert_eq!(
            format!("{:#}", result.unwrap_err()),
            "'types' list cannot be empty"
        );

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
        assert_eq!(
            format!("{:#}", result.unwrap_err()),
            "[http] addresses list is empty"
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
        let error = format!("{:#}", result.unwrap_err());
        assert_eq!(
            error,
            "[http] invalid URL 'not a valid url': relative URL without a base"
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
        assert_eq!(
            format!("{:#}", result.unwrap_err()),
            "Invalid HTTP version: 3. Must be 1 or 2."
        );

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_empty_http_versions() {
        let dir = std::env::temp_dir();
        let path = dir.join("empty_http_versions_config.toml");
        let config = example_config_content().replace("http_version = [1, 2]", "http_version = []");
        std::fs::write(&path, &config).unwrap();

        let result = LoadTestConfig::load(&path);
        assert_eq!(
            format!("{:#}", result.unwrap_err()),
            "http_version list cannot be empty"
        );

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
            "payload_size = \"56..1024\"",
            "payload_size = \"56..100000\"",
        );
        std::fs::write(&path, &config).unwrap();

        let result = LoadTestConfig::load(&path);
        let error = format!("{:#}", result.unwrap_err());
        assert_eq!(
            error,
            "[ping] payload_size.max (100000) exceeds maximum ICMP payload of 65507 bytes"
        );

        std::fs::remove_file(&path).ok();
    }
}
