//! Windows Event Log layer for tracing.
//!
//! Provides a `tracing` layer that writes events to the Windows Event Log.
//!
//! Inspired by the [`tracing-layer-win-eventlog`](https://github.com/itsscb/tracing-layer-win-eventlog)
//! crate (MIT licensed).
//!
//! # Level Filtering
//!
//! The layer supports independent filtering via the `EVENTLOG_DIRECTIVES` environment
//! variable. This allows controlling what gets written to the Windows Event Log
//! separately from `RUST_LOG`:
//!
//! ```ignore
//! // Set in environment:
//! // RUST_LOG=debug              # Console gets debug logs
//! // EVENTLOG_DIRECTIVES=warn    # Event Log only gets warn and above
//!
//! use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
//!
//! tracing_subscriber::registry()
//!     .with(logging::windows_event_log::filtered_layer("MyApp")?)
//!     .init();
//! ```
//!
//! If `EVENTLOG_DIRECTIVES` is not set, it defaults to `info`.
//!
//! # Event IDs
//!
//! Different log levels map to distinct Event IDs for filtering in Event Viewer:
//! - ERROR: Event ID 1
//! - WARN:  Event ID 2
//! - INFO:  Event ID 3
//! - DEBUG: Event ID 4
//! - TRACE: Event ID 5
//!
//! # Event Source Registration
//!
//! The layer attempts to auto-register the event source on creation.
//! This requires administrator privileges. If registration fails (no admin),
//! it falls back gracefully - the layer will still work if the source was
//! previously registered.
//!
//! To manually register a source (as admin):
//! ```powershell
//! New-EventLog -LogName Application -Source "MyApp"
//! ```

use std::fmt::Write as _;
use std::sync::{Arc, Mutex};

use tracing::field::{Field, Visit};
use tracing::span::Attributes;
use tracing::{Event, Id, Level, Subscriber};
use tracing_subscriber::filter::Filtered;
use tracing_subscriber::layer::Context;
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::{EnvFilter, Layer};

use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::EventLog::{
    DeregisterEventSource, EVENTLOG_ERROR_TYPE, EVENTLOG_INFORMATION_TYPE, EVENTLOG_WARNING_TYPE,
    REPORT_EVENT_TYPE, RegisterEventSourceW, ReportEventW,
};
use windows::Win32::System::Registry::{
    HKEY_LOCAL_MACHINE, KEY_WRITE, REG_DWORD, REG_EXPAND_SZ, REG_OPTION_NON_VOLATILE, RegCloseKey,
    RegCreateKeyExW, RegSetValueExW,
};
use windows::core::{PCWSTR, w};

// Event IDs 1-3 are defined in EventCreate.exe's message table
// with the "%1" format string for custom messages.
const EVENT_ID_ERROR: u32 = 1;
const EVENT_ID_WARNING: u32 = 2;
const EVENT_ID_INFO: u32 = 3;

/// Registry value for supported event types (Error | Warning | Information).
const TYPES_SUPPORTED: u32 = 0x07;

/// A thread-safe wrapper around the Windows Event Log handle.
struct EventSourceHandle {
    // Windows Event Log handles are NOT inherently thread-safe, so we use a
    // `Mutex` to serialize access. The handle is wrapped in an `Option` to
    // allow taking ownership during `Drop`.
    handle: Mutex<Option<HANDLE>>,
}

// SAFETY: EventSourceHandle is thread-safe because:
// 1. The HANDLE is protected by a Mutex, ensuring exclusive access
// 2. Windows Event Log handles can be used from any thread as long as access is serialised
// 3. The Mutex ensures only one thread accesses the handle at a time
unsafe impl Send for EventSourceHandle {}
unsafe impl Sync for EventSourceHandle {}

/// Environment variable for controlling Windows Event Log filtering.
///
/// Supports the same directive syntax as `RUST_LOG`.
pub const ENV_EVENTLOG_DIRECTIVES: &str = "EVENTLOG_DIRECTIVES";

/// Default filter directives when `EVENTLOG_DIRECTIVES` is not set.
const DEFAULT_DIRECTIVES: &str = "info";

impl EventSourceHandle {
    fn new(handle: HANDLE) -> Self {
        Self {
            handle: Mutex::new(Some(handle)),
        }
    }

    /// Reports an event to the Windows Event Log.
    fn report_event(&self, event_type: REPORT_EVENT_TYPE, event_id: u32, message: &str) {
        let message_wide = to_wide_string(message);
        let message_ptr = PCWSTR(message_wide.as_ptr());
        let messages = [message_ptr];

        let Ok(guard) = self.handle.lock() else {
            // Mutex is poisoned, skip logging
            #[cfg(debug_assertions)]
            eprintln!("Event Log handle mutex poisoned, skipping log");
            return;
        };

        let Some(handle) = *guard else {
            #[cfg(debug_assertions)]
            eprintln!("Event Log handle is not available, skipping log");
            return;
        };

        // SAFETY: We hold the mutex lock ensuring exclusive access to the handle.
        // The handle is valid (checked above) and message pointers are valid for
        // the duration of this call.
        unsafe {
            if let Err(_e) = ReportEventW(
                handle,
                event_type,
                0, // category
                event_id,
                None,            // user SID
                0,               // raw data size
                Some(&messages), // strings
                None,            // raw data
            ) {
                // Only log in debug builds to avoid noise in production.
                #[cfg(debug_assertions)]
                eprintln!("Failed to write to Windows Event Log: {_e}");
            }
        }
    }
}

impl Drop for EventSourceHandle {
    fn drop(&mut self) {
        // No need to lock - we have &mut self, so we're the only accessor
        if let Some(handle) = self.handle.get_mut().expect("not to be poisoned").take() {
            // SAFETY: We own the handle and only drop it once (ensured by `take()`).
            unsafe {
                let _ = DeregisterEventSource(handle);
            }
        }
    }
}

/// A [`tracing`] layer that writes events to the Windows Event Log.
pub struct WindowsEventLogLayer {
    handle: Arc<EventSourceHandle>,
}

impl WindowsEventLogLayer {
    /// Creates a new Event Log layer for the given source.
    ///
    /// Attempts to auto-register the source first (requires admin).
    /// Returns an error if the source cannot be opened.
    pub fn new(source: &str) -> Result<Self, Error> {
        // Try to register the source (may fail without admin - that's OK)
        if let Err(e) = try_register_source(source) {
            tracing::debug!(
                source,
                error = %e,
                "Could not register Event Log source (requires admin)"
            );
        }

        let source_wide = to_wide_string(source);
        // SAFETY: We pass valid pointers and the source string is null-terminated.
        let handle = unsafe { RegisterEventSourceW(PCWSTR::null(), PCWSTR(source_wide.as_ptr())) }
            .map_err(|e| Error::OpenSource {
                source: source.to_owned(),
                error: e,
            })?;

        Ok(Self {
            handle: Arc::new(EventSourceHandle::new(handle)),
        })
    }
}

/// Storage for span fields, attached to spans via extensions.
#[derive(Default)]
struct SpanFields {
    fields: Vec<(String, String)>,
}

/// Visitor for recording span fields into SpanFields storage.
struct SpanFieldVisitor<'a> {
    fields: &'a mut SpanFields,
}

impl Visit for SpanFieldVisitor<'_> {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        self.fields
            .fields
            .push((field.name().to_owned(), format!("{value:?}")));
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        self.fields
            .fields
            .push((field.name().to_owned(), value.to_owned()));
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.fields
            .fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.fields
            .fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_i128(&mut self, field: &Field, value: i128) {
        self.fields
            .fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_u128(&mut self, field: &Field, value: u128) {
        self.fields
            .fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        self.fields
            .fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_f64(&mut self, field: &Field, value: f64) {
        self.fields
            .fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_error(&mut self, field: &Field, value: &(dyn std::error::Error + 'static)) {
        self.fields
            .fields
            .push((field.name().to_owned(), value.to_string()));
    }
}

impl<S> Layer<S> for WindowsEventLogLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_new_span(&self, attrs: &Attributes<'_>, id: &Id, ctx: Context<'_, S>) {
        let Some(span) = ctx.span(id) else {
            return;
        };
        let mut fields = SpanFields::default();
        attrs.record(&mut SpanFieldVisitor {
            fields: &mut fields,
        });
        span.extensions_mut().insert(fields);
    }

    fn on_record(&self, id: &Id, values: &tracing::span::Record<'_>, ctx: Context<'_, S>) {
        let Some(span) = ctx.span(id) else {
            return;
        };
        let mut extensions = span.extensions_mut();
        if let Some(fields) = extensions.get_mut::<SpanFields>() {
            values.record(&mut SpanFieldVisitor { fields });
        }
    }

    fn on_event(&self, event: &Event<'_>, ctx: Context<'_, S>) {
        let metadata = event.metadata();
        let level = metadata.level();

        let (event_type, event_id) = match *level {
            Level::ERROR => (EVENTLOG_ERROR_TYPE, EVENT_ID_ERROR),
            Level::WARN => (EVENTLOG_WARNING_TYPE, EVENT_ID_WARNING),
            _ => (EVENTLOG_INFORMATION_TYPE, EVENT_ID_INFO),
        };

        // Build plain text message
        let mut visitor = EventVisitor::new();
        event.record(&mut visitor);

        // Collect span context with fields
        let span_context: Vec<SpanInfo> = ctx
            .event_scope(event)
            .map(|scope| {
                scope
                    .from_root()
                    .map(|span| {
                        let name = span.name().to_owned();
                        let fields = span
                            .extensions()
                            .get::<SpanFields>()
                            .map(|f| f.fields.clone())
                            .unwrap_or_default();
                        SpanInfo { name, fields }
                    })
                    .collect()
            })
            .unwrap_or_default();

        let message = visitor.into_message(&span_context);
        self.handle.report_event(event_type, event_id, &message);
    }
}

/// Information about a span including its name and fields.
struct SpanInfo {
    name: String,
    fields: Vec<(String, String)>,
}

/// Visitor that collects fields into a plain text message.
///
/// Output format:
/// ```text
/// <message>
/// span: <span1(field=value) / span2(field=value) / ...>
/// <field1>: <value1>
/// <field2>: <value2>
/// ```
struct EventVisitor {
    message: Option<String>,
    fields: Vec<(String, String)>,
}

impl EventVisitor {
    fn new() -> Self {
        Self {
            message: None,
            fields: Vec::new(),
        }
    }

    fn into_message(self, spans: &[SpanInfo]) -> String {
        let mut output = String::new();

        // Message first
        if let Some(msg) = &self.message {
            output.push_str(msg);
        }

        // Span context with fields
        if !spans.is_empty() {
            if !output.is_empty() {
                output.push('\n');
            }
            let span_str = spans
                .iter()
                .map(|s| {
                    if s.fields.is_empty() {
                        s.name.clone()
                    } else {
                        let fields_str = s
                            .fields
                            .iter()
                            .map(|(k, v)| format!("{k}={v}"))
                            .collect::<Vec<_>>()
                            .join(", ");
                        format!("{}({})", s.name, fields_str)
                    }
                })
                .collect::<Vec<_>>()
                .join(" / ");
            let _ = write!(output, "span: {span_str}");
        }

        // Event fields
        for (key, value) in &self.fields {
            if !output.is_empty() {
                output.push('\n');
            }
            let _ = write!(output, "{key}: {value}");
        }

        output
    }
}

impl Visit for EventVisitor {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        let value_str = format!("{value:?}");
        if field.name() == "message" {
            self.message = Some(value_str);
        } else {
            self.fields.push((field.name().to_owned(), value_str));
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "message" {
            self.message = Some(value.to_owned());
        } else {
            self.fields
                .push((field.name().to_owned(), value.to_owned()));
        }
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_i128(&mut self, field: &Field, value: i128) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_u128(&mut self, field: &Field, value: u128) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_f64(&mut self, field: &Field, value: f64) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_error(&mut self, field: &Field, value: &(dyn std::error::Error + 'static)) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }
}

/// Attempts to register an Event Log source.
///
/// This requires administrator privileges. If the source already exists,
/// this is a no-op.
fn try_register_source(source: &str) -> Result<(), Error> {
    let key_path = format!("SYSTEM\\CurrentControlSet\\Services\\EventLog\\Application\\{source}");
    let key_path_wide = to_wide_string(&key_path);

    let mut hkey = windows::Win32::System::Registry::HKEY::default();

    // SAFETY: We pass valid pointers and handle the result.
    unsafe {
        RegCreateKeyExW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(key_path_wide.as_ptr()),
            Some(0),
            PCWSTR::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_WRITE,
            None,
            &mut hkey,
            None,
        )
        .ok()
        .map_err(|e| Error::CreateRegistryKey { error: e })?;

        // Set TypesSupported (required for event types to work)
        let result = (|| {
            RegSetValueExW(
                hkey,
                w!("TypesSupported"),
                Some(0),
                REG_DWORD,
                Some(TYPES_SUPPORTED.to_le_bytes().as_slice()),
            )
            .ok()
            .map_err(|e| Error::SetRegistryValue { error: e })?;

            // Set EventMessageFile to a default message file
            // Using the system's default which handles %1 style messages
            let message_file = "%SystemRoot%\\System32\\EventCreate.exe";
            let message_file_wide = to_wide_string(message_file);
            let message_file_bytes: Vec<u8> = message_file_wide
                .iter()
                .flat_map(|&word| word.to_le_bytes())
                .collect();

            RegSetValueExW(
                hkey,
                w!("EventMessageFile"),
                Some(0),
                REG_EXPAND_SZ,
                Some(&message_file_bytes),
            )
            .ok()
            .map_err(|e| Error::SetRegistryValue { error: e })?;

            Ok(())
        })();

        // Always close the registry key
        let _ = RegCloseKey(hkey);

        result
    }
}

/// Converts a Rust string to a null-terminated wide string (UTF-16).
fn to_wide_string(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Creates a new Windows Event Log layer without filtering.
///
/// Attempts to auto-register the source (requires admin privileges).
/// Falls back gracefully if registration fails but the source exists.
///
/// **Note:** This layer logs all events regardless of level. For independent
/// filtering, use [`filtered_layer`] instead.
///
/// # Errors
///
/// Returns an error if the event source cannot be opened. This typically
/// means the source was never registered. Register it manually with:
///
/// ```powershell
/// New-EventLog -LogName Application -Source "YourSourceName"
/// ```
pub fn layer(source: &str) -> Result<WindowsEventLogLayer, Error> {
    WindowsEventLogLayer::new(source)
}

/// Creates a Windows Event Log layer with filtering from `EVENTLOG_DIRECTIVES`.
///
/// This allows independent control of what gets logged to the Windows Event Log,
/// separate from the `RUST_LOG` environment variable.
///
/// # Environment Variable
///
/// Set `EVENTLOG_DIRECTIVES` to control filtering:
/// - `warn` - only warnings and errors
/// - `info` - info, warnings, and errors (default)
/// - `debug` - debug and above
/// - `mymodule=debug,warn` - debug for mymodule, warn for everything else
///
/// If not set, defaults to `info`.
///
/// # Errors
///
/// Returns an error if the event source cannot be opened or if the filter
/// directives are invalid.
pub fn filtered_layer<S>(
    source: &str,
) -> Result<Filtered<WindowsEventLogLayer, EnvFilter, S>, Error>
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    let directives =
        std::env::var(ENV_EVENTLOG_DIRECTIVES).unwrap_or_else(|_| DEFAULT_DIRECTIVES.to_owned());

    filtered_layer_with_directives(source, &directives)
}

/// Creates a Windows Event Log layer with custom filter directives.
///
/// Use this when you want to specify directives programmatically rather than
/// via environment variable.
///
/// # Errors
///
/// Returns an error if the event source cannot be opened or if the filter
/// directives are invalid.
pub fn filtered_layer_with_directives<S>(
    source: &str,
    directives: &str,
) -> Result<Filtered<WindowsEventLogLayer, EnvFilter, S>, Error>
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    let layer = WindowsEventLogLayer::new(source)?;
    let filter = EnvFilter::try_new(directives).map_err(|error| Error::InvalidDirectives {
        directives: directives.to_owned(),
        error: error.to_string(),
    })?;

    Ok(layer.with_filter(filter))
}

/// Errors that can occur when working with the Windows Event Log.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// Failed to open the event source.
    #[error(
        "Failed to open Event Log source '{source}': {error}. \
        Run as admin once or use: New-EventLog -LogName Application -Source \"{source}\""
    )]
    OpenSource {
        source: String,
        #[source]
        error: windows::core::Error,
    },

    /// Failed to create registry key (requires admin).
    #[error("Failed to create registry key (requires admin): {error}")]
    CreateRegistryKey {
        #[source]
        error: windows::core::Error,
    },

    /// Failed to set registry value.
    #[error("Failed to set registry value: {error}")]
    SetRegistryValue {
        #[source]
        error: windows::core::Error,
    },

    /// Invalid filter directives.
    #[error("Invalid filter directives '{directives}': {error}")]
    InvalidDirectives { directives: String, error: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_visitor_builds_message_with_fields() {
        let mut visitor = EventVisitor::new();
        visitor.message = Some("test message".to_owned());
        visitor.fields.push(("count".to_owned(), "42".to_owned()));
        visitor.fields.push(("name".to_owned(), "test".to_owned()));

        let spans = vec![
            SpanInfo {
                name: "span1".to_owned(),
                fields: vec![("id".to_owned(), "123".to_owned())],
            },
            SpanInfo {
                name: "span2".to_owned(),
                fields: vec![],
            },
        ];

        let output = visitor.into_message(&spans);

        assert!(output.contains("test message"));
        assert!(output.contains("span: span1(id=123) / span2"));
        assert!(output.contains("count: 42"));
        assert!(output.contains("name: test"));
    }

    #[test]
    fn event_visitor_handles_empty_spans() {
        let mut visitor = EventVisitor::new();
        visitor.message = Some("test".to_owned());

        let output = visitor.into_message(&[]);

        assert_eq!(output, "test");
        assert!(!output.contains("span:"));
    }

    #[test]
    fn event_visitor_handles_no_message() {
        let mut visitor = EventVisitor::new();
        visitor.fields.push(("key".to_owned(), "value".to_owned()));

        let output = visitor.into_message(&[]);

        assert_eq!(output, "key: value");
    }

    #[test]
    fn to_wide_string_includes_null_terminator() {
        let wide = to_wide_string("test");
        assert_eq!(wide.len(), 5); // 4 chars + null
        assert_eq!(wide[4], 0);
    }

    #[test]
    fn to_wide_string_handles_unicode() {
        // Test various Unicode characters
        let wide = to_wide_string("héllo wörld 日本語 🔥");
        assert_eq!(*wide.last().unwrap(), 0, "Should be null-terminated");

        // Verify it round-trips correctly
        let without_null = &wide[..wide.len() - 1];
        let back = String::from_utf16(without_null).unwrap();
        assert_eq!(back, "héllo wörld 日本語 🔥");
    }

    #[test]
    fn to_wide_string_handles_empty() {
        let wide = to_wide_string("");
        assert_eq!(wide.len(), 1); // Just null terminator
        assert_eq!(wide[0], 0);
    }

    #[test]
    fn event_visitor_spans_without_message() {
        let visitor = EventVisitor::new();
        let spans = vec![SpanInfo {
            name: "outer".to_owned(),
            fields: vec![("id".to_owned(), "1".to_owned())],
        }];

        let output = visitor.into_message(&spans);

        assert_eq!(output, "span: outer(id=1)");
    }

    #[test]
    fn event_visitor_nested_spans() {
        let visitor = EventVisitor::new();
        let spans = vec![
            SpanInfo {
                name: "root".to_owned(),
                fields: vec![],
            },
            SpanInfo {
                name: "middle".to_owned(),
                fields: vec![("a".to_owned(), "1".to_owned())],
            },
            SpanInfo {
                name: "leaf".to_owned(),
                fields: vec![
                    ("b".to_owned(), "2".to_owned()),
                    ("c".to_owned(), "3".to_owned()),
                ],
            },
        ];

        let output = visitor.into_message(&spans);

        assert_eq!(output, "span: root / middle(a=1) / leaf(b=2, c=3)");
    }

    #[test]
    fn event_visitor_record_primitives() {
        use tracing::field::Field;

        let mut visitor = EventVisitor::new();

        // Create a fake field for testing
        struct FakeField(&'static str);
        impl FakeField {
            fn as_field(&self) -> Field {
                // Get field from the test metadata's field set
                METADATA.fields().field(self.0).unwrap()
            }
        }

        struct TestCallsite;
        static CALLSITE: TestCallsite = TestCallsite;

        impl tracing::Callsite for TestCallsite {
            fn set_interest(&self, _: tracing::subscriber::Interest) {}
            fn metadata(&self) -> &tracing::Metadata<'_> {
                &METADATA
            }
        }

        static METADATA: tracing::Metadata<'static> = tracing::Metadata::new(
            "test",
            "test",
            tracing::Level::INFO,
            Some(file!()),
            Some(line!()),
            Some(module_path!()),
            tracing::field::FieldSet::new(
                &["i64_field", "u64_field", "bool_field", "f64_field"],
                tracing::callsite::Identifier(&CALLSITE),
            ),
            tracing::metadata::Kind::EVENT,
        );

        visitor.record_i64(&FakeField("i64_field").as_field(), -42);
        visitor.record_u64(&FakeField("u64_field").as_field(), 123);
        visitor.record_bool(&FakeField("bool_field").as_field(), true);
        visitor.record_f64(&FakeField("f64_field").as_field(), 2.88);

        let output = visitor.into_message(&[]);

        assert!(output.contains("i64_field: -42"), "got: {output}");
        assert!(output.contains("u64_field: 123"), "got: {output}");
        assert!(output.contains("bool_field: true"), "got: {output}");
        assert!(output.contains("f64_field: 2.88"), "got: {output}");
    }

    #[test]
    fn error_display_messages() {
        let err = Error::InvalidDirectives {
            directives: "invalid[".to_owned(),
            error: "parse error".to_owned(),
        };
        let msg = err.to_string();
        assert!(msg.contains("invalid["), "got: {msg}");
        assert!(msg.contains("parse error"), "got: {msg}");
    }
}
