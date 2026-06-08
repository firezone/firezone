//! TOML configuration for randomized load testing.
//!
//! Every section is optional - see loadtest.example.toml for the available options.
//! Each invocation randomly selects a test type from the sections that are present
//! and picks parameters from its config.

use crate::cli::parse_bitrate;
use crate::turn::TURN_HEADER_SIZE;
use anyhow::{Context as _, Result, bail};
use rand::distributions::uniform::SampleRange;
use rand::prelude::*;
use serde::Deserialize;
use std::net::SocketAddr;
use std::path::Path;
use url::Url;

/// Top-level configuration loaded from TOML.
///
/// Each section is optional; a random test is selected from whichever
/// sections are present.
#[derive(Debug, Deserialize)]
pub struct LoadTestConfig {
    pub http: Option<HttpConfig>,
    pub tcp: Option<TcpConfig>,
    pub websocket: Option<WebsocketConfig>,
    pub turn: Option<TurnConfig>,
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
        // An inclusive `[min, max]` range is only empty when `min > max`; when the
        // bounds are equal it still contains that single value.
        self.min > self.max
    }
}

/// HTTP load test configuration.
#[derive(Debug, Deserialize)]
pub struct HttpConfig {
    /// List of target URLs to choose from.
    pub addresses: Vec<String>,
    /// HTTP versions to choose from (1 or 2).
    pub http_version: Vec<u8>,
    /// Maximum number of concurrent connections.
    pub max_connections: u64,
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
    /// How long to at most wait between messages. Zero means we won't send any messages.
    pub max_echo_interval_secs: u64,
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

/// Maximum TURN payload size.
///
/// Bounded by a conservative typical Internet MTU to avoid IP fragmentation of
/// the relayed datagrams.
pub const MAX_TURN_PAYLOAD_SIZE: usize = 1400;

/// TURN (relay) load test configuration.
///
/// Unlike the other sections, a TURN test targets a single relay with a single
/// set of credentials, so its fields are scalars rather than lists or ranges.
#[derive(Debug, Clone, Deserialize)]
pub struct TurnConfig {
    /// Relay socket address (`ip:port`).
    pub address: SocketAddr,
    /// TURN username (long-term credential, scoped to this relay).
    pub username: String,
    /// TURN password (long-term credential, scoped to this relay).
    pub password: String,
    /// UDP payload size in bytes for each relayed datagram.
    #[serde(default = "default_turn_payload_size")]
    pub payload_size: usize,
    /// Target send bitrate in bits per second (e.g. "2mbps", "500kbps").
    #[serde(rename = "bitrate", deserialize_with = "deserialize_bitrate")]
    pub bitrate_bps: u64,
    /// How long to stream datagrams for, in seconds.
    #[serde(default = "default_turn_duration_secs")]
    pub duration_secs: u64,
    /// Fail the test if packet loss exceeds this percentage.
    pub max_loss_percent: Option<f64>,
}

/// Default TURN payload size (a typical media MTU).
fn default_turn_payload_size() -> usize {
    1280
}

/// Default TURN test duration in seconds.
fn default_turn_duration_secs() -> u64 {
    30
}

fn deserialize_bitrate<'de, D>(d: D) -> Result<u64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::Error as _;

    let string = String::deserialize(d)?;
    parse_bitrate(&string).map_err(D::Error::custom)
}

impl TurnConfig {
    fn validate(&self) -> Result<()> {
        if self.username.is_empty() {
            bail!("[turn] username is empty");
        }
        if self.password.is_empty() {
            bail!("[turn] password is empty");
        }
        if self.payload_size < TURN_HEADER_SIZE {
            bail!(
                "[turn] payload_size ({}) must be at least {TURN_HEADER_SIZE} bytes (sequence header)",
                self.payload_size
            );
        }
        if self.payload_size > MAX_TURN_PAYLOAD_SIZE {
            bail!(
                "[turn] payload_size ({}) exceeds the maximum of {MAX_TURN_PAYLOAD_SIZE} bytes",
                self.payload_size
            );
        }
        if self.bitrate_bps == 0 {
            bail!("[turn] bitrate must be greater than zero");
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
        if let Some(http) = &self.http {
            http.validate()?;
        }
        if let Some(tcp) = &self.tcp {
            tcp.validate()?;
        }
        if let Some(websocket) = &self.websocket {
            websocket.validate()?;
        }
        if let Some(turn) = &self.turn {
            turn.validate()?;
        }

        Ok(())
    }

    /// The test types that have a config section present, in a stable order.
    pub fn enabled_types(&self) -> Vec<TestType> {
        [
            self.http.is_some().then_some(TestType::Http),
            self.tcp.is_some().then_some(TestType::Tcp),
            self.websocket.is_some().then_some(TestType::Websocket),
            self.turn.is_some().then_some(TestType::Turn),
        ]
        .into_iter()
        .flatten()
        .collect()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TestType {
    Http,
    Tcp,
    Websocket,
    Turn,
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
    fn test_load_empty_config() {
        let dir = std::env::temp_dir();
        let path = dir.join("empty_config.toml");
        // A config with no test sections is valid; it simply enables nothing.
        std::fs::write(&path, "# Empty config\n").unwrap();

        let config = LoadTestConfig::load(&path).unwrap();
        assert!(config.enabled_types().is_empty());

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
        std::fs::write(&path, example_config_content()).unwrap();

        let result = LoadTestConfig::load(&path);
        assert!(result.is_ok());

        let config = result.unwrap();
        assert_eq!(
            config.enabled_types(),
            vec![TestType::Http, TestType::Tcp, TestType::Websocket]
        );

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_with_optional_sections_omitted() {
        let dir = std::env::temp_dir();
        let path = dir.join("optional_sections_config.toml");
        // Only the [http] section is present; the others are omitted.
        std::fs::write(
            &path,
            "[http]\naddresses = [\"https://example.com\"]\nhttp_version = [1, 2]\nmax_connections = 100\n",
        )
        .unwrap();

        let result = LoadTestConfig::load(&path);
        assert!(result.is_ok());

        let config = result.unwrap();
        assert_eq!(config.enabled_types(), vec![TestType::Http]);

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_turn_section() {
        let dir = std::env::temp_dir();
        let path = dir.join("turn_config.toml");
        std::fs::write(
            &path,
            "[turn]\naddress = \"1.2.3.4:3478\"\nusername = \"u\"\npassword = \"p\"\nbitrate = \"2mbps\"\n",
        )
        .unwrap();

        let config = LoadTestConfig::load(&path).unwrap();
        assert_eq!(config.enabled_types(), vec![TestType::Turn]);

        let turn = config.turn.unwrap();
        assert_eq!(turn.bitrate_bps, 2_000_000);
        assert_eq!(turn.payload_size, 1280); // default
        assert_eq!(turn.duration_secs, 30); // default
        assert_eq!(turn.address, "1.2.3.4:3478".parse().unwrap());

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_turn_rejects_small_payload() {
        let dir = std::env::temp_dir();
        let path = dir.join("turn_small_payload.toml");
        std::fs::write(
            &path,
            "[turn]\naddress = \"1.2.3.4:3478\"\nusername = \"u\"\npassword = \"p\"\nbitrate = \"1mbps\"\npayload_size = 8\n",
        )
        .unwrap();

        let result = LoadTestConfig::load(&path);
        assert_eq!(
            format!("{:#}", result.unwrap_err()),
            "[turn] payload_size (8) must be at least 16 bytes (sequence header)"
        );

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn range_with_equal_bounds_is_not_empty() {
        // `gen_range` panics on a range it believes is empty; an inclusive range
        // with equal bounds still contains its single value.
        assert!(!Range { min: 5, max: 5 }.is_empty());
        assert!(Range { min: 6, max: 5 }.is_empty());
    }
}
