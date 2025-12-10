//! Integration tests for Windows Event Log layer.
//!
//! These tests require Windows and write to the actual Event Log.
//! Run with: `cargo test --test windows_event_log_integration -- --include-ignored`

#![cfg(windows)]

use std::process::Command;

use tracing_subscriber::layer::SubscriberExt as _;
use tracing_subscriber::util::SubscriberInitExt as _;

/// Unique source name for testing to avoid conflicts.
///
/// Uses process ID and a unique suffix to ensure each test has its own source.
fn test_source(suffix: &str) -> String {
    format!("Firezone-Test-{}-{suffix}", std::process::id())
}

/// Guard that removes the Event Log source on drop.
///
/// Ensures cleanup happens even if a test panics.
struct SourceGuard(String);

impl Drop for SourceGuard {
    fn drop(&mut self) {
        remove_source(&self.0);
    }
}

/// Registers an Event Log source using PowerShell.
fn register_source(source: &str) -> bool {
    let output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            &format!(
                "New-EventLog -LogName Application -Source '{}' -ErrorAction SilentlyContinue",
                source
            ),
        ])
        .output();

    output.is_ok_and(|o| o.status.success() || o.stderr.is_empty())
}

/// Removes an Event Log source using PowerShell.
fn remove_source(source: &str) {
    let _ = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            &format!(
                "Remove-EventLog -Source '{}' -ErrorAction SilentlyContinue",
                source
            ),
        ])
        .output();
}

/// Reads the most recent event from the specified source.
fn read_latest_event(source: &str) -> Option<String> {
    let output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            &format!(
                "Get-WinEvent -LogName Application -FilterXPath \"*[System[Provider[@Name='{source}']]]\" -MaxEvents 1 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Message"
            ),
        ])
        .output()
        .ok()?;

    if output.status.success() && !output.stdout.is_empty() {
        Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        None
    }
}

/// Debug helper: lists all events from a source.
#[allow(dead_code)]
fn debug_list_events(source: &str) -> String {
    let output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            &format!(
                "Get-WinEvent -LogName Application -FilterXPath \"*[System[Provider[@Name='{source}']]]\" -MaxEvents 10 -ErrorAction SilentlyContinue | Select-Object TimeCreated, Message | Format-List"
            ),
        ])
        .output();

    match output {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            let stderr = String::from_utf8_lossy(&o.stderr);
            format!("stdout: {stdout}\nstderr: {stderr}")
        }
        Err(e) => format!("Failed to run PowerShell: {e}"),
    }
}

#[test]
#[ignore = "Requires Windows and may need admin privileges"]
fn writes_event_to_event_log() {
    let source = test_source("writes");
    let _cleanup = SourceGuard(source.clone());

    // Clean up any previous test runs
    remove_source(&source);

    // Register the source (may fail without admin - that's OK, auto-registration may work)
    let _ = register_source(&source);

    // Create the layer
    let layer = logging::windows_event_log::layer(&source)
        .expect("Failed to create Event Log layer (need admin?)");

    // Set up tracing with our layer
    let _subscriber = tracing_subscriber::registry().with(layer).set_default();

    // Write a test event
    let test_message = format!("Integration test event {}", std::process::id());
    tracing::info!(test_field = "test_value", number = 42, "{test_message}");

    // Give Windows a moment to process the event
    std::thread::sleep(std::time::Duration::from_millis(500));

    // Read it back
    let event_content = read_latest_event(&source);

    // Verify (cleanup happens via SourceGuard on drop)
    let content = event_content.unwrap_or_else(|| {
        panic!(
            "Should have read an event from source '{source}'. Debug: {}",
            debug_list_events(&source)
        )
    });
    assert!(
        content.contains(&test_message) || content.contains("Integration test event"),
        "Event should contain our message, got: {content}\nSource: {source}\nDebug: {}",
        debug_list_events(&source)
    );
    assert!(
        content.contains("test_field") || content.contains("test_value"),
        "Event should contain our field, got: {content}"
    );
}

#[test]
#[ignore = "Requires Windows and may need admin privileges"]
fn maps_log_levels_correctly() {
    let source = test_source("levels");
    let _cleanup = SourceGuard(source.clone());

    remove_source(&source);
    let _ = register_source(&source);

    let layer =
        logging::windows_event_log::layer(&source).expect("Failed to create Event Log layer");

    let _subscriber = tracing_subscriber::registry().with(layer).set_default();

    // Write events at different levels
    tracing::error!("error level test");
    tracing::warn!("warn level test");
    tracing::info!("info level test");

    std::thread::sleep(std::time::Duration::from_millis(500));

    // Read events and check they exist
    let output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            &format!(
                "Get-WinEvent -LogName Application -FilterXPath \"*[System[Provider[@Name='{}']]]\" -MaxEvents 3 | Select-Object Level, Message | ConvertTo-Json",
                source
            ),
        ])
        .output()
        .expect("PowerShell should run");

    assert!(
        output.status.success(),
        "Should read events: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let events = String::from_utf8_lossy(&output.stdout);
    assert!(
        events.contains("error level test"),
        "Should have error event"
    );
    assert!(events.contains("warn level test"), "Should have warn event");
    assert!(events.contains("info level test"), "Should have info event");
}

#[test]
#[ignore = "Requires Windows and may need admin privileges"]
fn captures_span_fields() {
    let source = test_source("spans");
    let _cleanup = SourceGuard(source.clone());

    remove_source(&source);
    let _ = register_source(&source);

    let layer =
        logging::windows_event_log::layer(&source).expect("Failed to create Event Log layer");

    let _subscriber = tracing_subscriber::registry().with(layer).set_default();

    // Create a span with fields and emit an event inside it
    let span = tracing::info_span!("request", method = "GET", path = "/api/test");
    let _enter = span.enter();

    tracing::info!("handling request");

    std::thread::sleep(std::time::Duration::from_millis(500));

    let event_content = read_latest_event(&source);

    let content = event_content.unwrap_or_else(|| {
        panic!(
            "Should have read an event from source '{source}'. Debug: {}",
            debug_list_events(&source)
        )
    });
    assert!(
        content.contains("handling request"),
        "Event should contain our message, got: {content}\nSource: {source}\nDebug: {}",
        debug_list_events(&source)
    );
    assert!(
        content.contains("request") && content.contains("method=GET"),
        "Event should contain span name and fields, got: {content}"
    );
}
