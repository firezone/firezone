#![allow(clippy::unwrap_used)]

//! Integration tests for loadtest functionality.
//!
//! Tests various modes of firezone-loadtest:
//! - Echo mode (TCP and WebSocket)
//! - ICMP ping testing (requires elevated privileges)

use std::net::TcpListener;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

/// RAII guard for cleaning up server processes.
///
/// Ensures the server is killed even if the test panics.
struct ServerGuard(Child);

impl Drop for ServerGuard {
    fn drop(&mut self) {
        self.0.kill().ok();
        self.0.wait().ok();
    }
}

/// Get the path to the target directory where compiled binaries are located.
fn target_dir() -> PathBuf {
    // The test binary is in target/debug/deps, so go up to target/debug
    let mut path = std::env::current_exe().expect("Failed to get current exe path");
    path.pop(); // Remove the test binary name
    path.pop(); // Remove deps
    path
}

/// Find an available port by binding to port 0.
fn find_available_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("Failed to bind to port 0")
        .local_addr()
        .expect("Failed to get local address")
        .port()
}

/// Wait for a TCP port to become available.
fn wait_for_port(port: u16, timeout: Duration) -> bool {
    let start = std::time::Instant::now();
    while start.elapsed() < timeout {
        if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

/// Spawn a TCP echo server using firezone-loadtest.
fn spawn_tcp_server(port: u16) -> Child {
    let binary = target_dir().join("firezone-loadtest");
    Command::new(&binary)
        .args(["tcp", "--server", "-p", &port.to_string()])
        .env("RUST_LOG", "warn")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap_or_else(|e| {
            panic!(
                "Failed to spawn firezone-loadtest TCP server at {}: {e}",
                binary.display()
            )
        })
}

/// Spawn a WebSocket echo server using firezone-loadtest.
fn spawn_ws_server(port: u16) -> Child {
    let binary = target_dir().join("firezone-loadtest");
    Command::new(&binary)
        .args(["websocket", "--server", "-p", &port.to_string()])
        .env("RUST_LOG", "warn")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap_or_else(|e| {
            panic!(
                "Failed to spawn firezone-loadtest WebSocket server at {}: {e}",
                binary.display()
            )
        })
}

/// Result of running the loadtest binary.
struct LoadtestOutput {
    stdout: String,
    stderr: String,
    success: bool,
}

/// Run the loadtest binary and return its stdout.
fn run_loadtest(args: &[&str]) -> String {
    let output = try_run_loadtest(args);
    if !output.success {
        panic!(
            "firezone-loadtest failed\nstdout: {}\nstderr: {}",
            output.stdout, output.stderr
        );
    }
    output.stdout
}

/// Try to run the loadtest binary, returning the result without panicking.
fn try_run_loadtest(args: &[&str]) -> LoadtestOutput {
    let binary = target_dir().join("firezone-loadtest");
    let output = Command::new(&binary)
        .args(args)
        .env("RUST_LOG", "warn")
        .output()
        .unwrap_or_else(|e| {
            panic!(
                "Failed to run firezone-loadtest at {}: {e}",
                binary.display()
            )
        });

    LoadtestOutput {
        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).to_string(),
        success: output.status.success(),
    }
}

/// Summary structure for parsing TCP test results.
#[derive(Debug, serde::Deserialize)]
struct TcpSummary {
    test_type: String,
    successful_connections: usize,
    failed_connections: usize,
    echo_mode: bool,
    echo_messages_sent: Option<usize>,
    echo_messages_verified: Option<usize>,
    echo_mismatches: Option<usize>,
}

/// Summary structure for parsing WebSocket test results.
#[derive(Debug, serde::Deserialize)]
struct WebsocketSummary {
    test_type: String,
    successful_connections: usize,
    failed_connections: usize,
    echo_mode: bool,
    echo_messages_sent: Option<usize>,
    echo_messages_verified: Option<usize>,
    echo_mismatches: Option<usize>,
}

/// Summary structure for parsing ping test results.
#[derive(Debug, serde::Deserialize)]
struct PingSummary {
    test_type: String,
    packets_sent: usize,
    packets_received: usize,
    packet_loss_percent: f64,
}

#[test]
fn test_tcp_echo_integration() {
    let tcp_port = find_available_port();

    // ServerGuard ensures cleanup even if the test panics
    let _server = ServerGuard(spawn_tcp_server(tcp_port));

    // Wait for the TCP server to be ready
    assert!(
        wait_for_port(tcp_port, Duration::from_secs(5)),
        "TCP echo server port {tcp_port} did not become available"
    );

    // Run loadtest with echo mode for 3 seconds
    let target = format!("127.0.0.1:{tcp_port}");
    let output = run_loadtest(&[
        "tcp",
        "--target",
        &target,
        "--echo",
        "-c",
        "3",
        "-d",
        "3s",
        "--echo-interval",
        "500ms",
    ]);

    // Parse the JSON output
    let summary: TcpSummary = serde_json::from_str(&output)
        .unwrap_or_else(|e| panic!("Failed to parse output as JSON: {e}\nOutput: {output}"));

    // Verify results
    assert_eq!(summary.test_type, "tcp");
    assert!(summary.echo_mode);
    assert_eq!(
        summary.successful_connections, 3,
        "Expected 3 successful connections, got {}. Full output: {output}",
        summary.successful_connections
    );
    assert_eq!(
        summary.failed_connections, 0,
        "Expected 0 failed connections, got {}",
        summary.failed_connections
    );
    assert_eq!(
        summary.echo_mismatches,
        Some(0),
        "Expected 0 echo mismatches, got {:?}",
        summary.echo_mismatches
    );
    assert!(
        summary.echo_messages_sent.unwrap_or(0) > 0,
        "Expected some echo messages to be sent"
    );
    assert!(
        summary.echo_messages_verified.unwrap_or(0) > 0,
        "Expected some echo messages to be verified"
    );
}

#[test]
fn test_websocket_echo_integration() {
    let ws_port = find_available_port();

    // ServerGuard ensures cleanup even if the test panics
    let _server = ServerGuard(spawn_ws_server(ws_port));

    // Wait for the WebSocket server to be ready
    assert!(
        wait_for_port(ws_port, Duration::from_secs(5)),
        "WebSocket echo server port {ws_port} did not become available"
    );

    // Run loadtest with echo mode for 3 seconds
    let url = format!("ws://127.0.0.1:{ws_port}");
    let output = run_loadtest(&[
        "websocket",
        "--url",
        &url,
        "--echo",
        "-c",
        "3",
        "-d",
        "3s",
        "--echo-interval",
        "500ms",
    ]);

    // Parse the JSON output
    let summary: WebsocketSummary = serde_json::from_str(&output)
        .unwrap_or_else(|e| panic!("Failed to parse output as JSON: {e}\nOutput: {output}"));

    // Verify results
    assert_eq!(summary.test_type, "websocket");
    assert!(summary.echo_mode);
    assert_eq!(
        summary.successful_connections, 3,
        "Expected 3 successful connections, got {}. Full output: {output}",
        summary.successful_connections
    );
    assert_eq!(
        summary.failed_connections, 0,
        "Expected 0 failed connections, got {}",
        summary.failed_connections
    );
    assert_eq!(
        summary.echo_mismatches,
        Some(0),
        "Expected 0 echo mismatches, got {:?}",
        summary.echo_mismatches
    );
    assert!(
        summary.echo_messages_sent.unwrap_or(0) > 0,
        "Expected some echo messages to be sent"
    );
    assert!(
        summary.echo_messages_verified.unwrap_or(0) > 0,
        "Expected some echo messages to be verified"
    );
}

#[test]
fn test_ping_localhost_integration() {
    // Ping test requires elevated privileges (root or CAP_NET_RAW).
    // If we don't have privileges, skip the test gracefully.

    let output = try_run_loadtest(&[
        "ping",
        "--target",
        "127.0.0.1",
        "-c",
        "3",
        "-i",
        "100ms",
        "--timeout",
        "1s",
    ]);

    if !output.success {
        // Check if the failure is due to insufficient privileges
        if output.stderr.contains("elevated privileges")
            || output.stderr.contains("CAP_NET_RAW")
            || output.stderr.contains("Operation not permitted")
            || output.stderr.contains("Permission denied")
        {
            tracing::warn!(
                "Skipping ping test: insufficient privileges (requires root or CAP_NET_RAW)"
            );
            return;
        }
        // Some other failure - that's a real test failure
        panic!(
            "Ping test failed unexpectedly\nstdout: {}\nstderr: {}",
            output.stdout, output.stderr
        );
    }

    // Parse the JSON output
    let summary: PingSummary = serde_json::from_str(&output.stdout).unwrap_or_else(|e| {
        panic!(
            "Failed to parse output as JSON: {e}\nOutput: {}",
            output.stdout
        )
    });

    // Verify results
    assert_eq!(summary.test_type, "ping");
    assert_eq!(summary.packets_sent, 3, "Expected 3 packets sent");
    assert!(
        summary.packets_received > 0,
        "Expected at least one ping reply from localhost"
    );
    // Localhost should have no packet loss
    assert!(
        summary.packet_loss_percent < 50.0,
        "Expected minimal packet loss to localhost, got {}%",
        summary.packet_loss_percent
    );
}
