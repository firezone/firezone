//! Windows Event Log layer for tracing.
//!
//! Provides a `tracing` layer that writes events to the Windows Event Log.
//!
//! Inspired by the [`tracing-layer-win-eventlog`](https://github.com/itsscb/tracing-layer-win-eventlog)
//! crate (MIT licensed).
//! Filters via `EVENTLOG_DIRECTIVES` env var (default: `info`), independent of `RUST_LOG`.
//!
//! ```ignore
//! tracing_subscriber::registry()
//!     .with(logging::windows_event_log::layer("MyApp")?)
//!     .init();
//! ```
//!
//! Event IDs: ERROR=1, WARN=2, INFO/DEBUG/TRACE=3 (supported by `EventCreate.exe`).
//!
//! Auto-registers the source on creation (requires admin). To register manually:
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

const EVENT_ID_ERROR: u32 = 1;
const EVENT_ID_WARNING: u32 = 2;
const EVENT_ID_INFO: u32 = 3;
const TYPES_SUPPORTED: u32 = 0x07; // Error | Warning | Information

/// Thread-safe wrapper around the Windows Event Log handle.
struct EventSourceHandle {
    handle: Mutex<Option<HANDLE>>,
}

// SAFETY: Access is serialized via Mutex.
unsafe impl Send for EventSourceHandle {}
unsafe impl Sync for EventSourceHandle {}

impl EventSourceHandle {
    fn new(handle: HANDLE) -> Self {
        Self {
            handle: Mutex::new(Some(handle)),
        }
    }

    fn report_event(&self, event_type: REPORT_EVENT_TYPE, event_id: u32, message: &str) {
        let message_wide = to_wide_string(message);
        let messages = [PCWSTR(message_wide.as_ptr())];

        let Ok(guard) = self.handle.lock() else {
            return;
        };
        let Some(handle) = *guard else {
            return;
        };

        // SAFETY: Handle is valid and protected by mutex.
        unsafe {
            let _ = ReportEventW(
                handle,
                event_type,
                0,
                event_id,
                None,
                0,
                Some(&messages),
                None,
            );
        }
    }
}

impl Drop for EventSourceHandle {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.get_mut().expect("not poisoned").take() {
            // SAFETY: We own the handle.
            unsafe {
                let _ = DeregisterEventSource(handle);
            }
        }
    }
}

/// A tracing layer that writes events to the Windows Event Log.
pub struct Layer {
    handle: Arc<EventSourceHandle>,
}

impl Layer {
    fn new(source: &str) -> Result<Self, Error> {
        let _ = try_register_source(source);

        let source_wide = to_wide_string(source);
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

/// Storage for span fields.
#[derive(Default)]
struct SpanFields {
    fields: Vec<(String, String)>,
}

impl<S> Layer<S> for Layer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_new_span(&self, attrs: &Attributes<'_>, id: &Id, ctx: Context<'_, S>) {
        if let Some(span) = ctx.span(id) {
            let mut fields = SpanFields::default();
            attrs.record(&mut FieldVisitor(&mut fields.fields));
            span.extensions_mut().insert(fields);
        }
    }

    fn on_record(&self, id: &Id, values: &tracing::span::Record<'_>, ctx: Context<'_, S>) {
        if let Some(span) = ctx.span(id) {
            let mut extensions = span.extensions_mut();
            if let Some(fields) = extensions.get_mut::<SpanFields>() {
                values.record(&mut FieldVisitor(&mut fields.fields));
            }
        }
    }

    fn on_event(&self, event: &Event<'_>, ctx: Context<'_, S>) {
        let level = event.metadata().level();

        let (event_type, event_id) = match *level {
            Level::ERROR => (EVENTLOG_ERROR_TYPE, EVENT_ID_ERROR),
            Level::WARN => (EVENTLOG_WARNING_TYPE, EVENT_ID_WARNING),
            _ => (EVENTLOG_INFORMATION_TYPE, EVENT_ID_INFO),
        };

        let mut message = None;
        let mut fields = Vec::new();
        event.record(&mut EventVisitor {
            message: &mut message,
            fields: &mut fields,
        });

        let spans: Vec<_> = ctx
            .event_scope(event)
            .map(|scope| {
                scope
                    .from_root()
                    .map(|span| {
                        let name = span.name();
                        let fields = span
                            .extensions()
                            .get::<SpanFields>()
                            .map(|f| f.fields.clone())
                            .unwrap_or_default();
                        (name, fields)
                    })
                    .collect()
            })
            .unwrap_or_default();

        let output = format_message(message.as_deref(), &spans, &fields);
        self.handle.report_event(event_type, event_id, &output);
    }
}

/// Visitor for recording fields as key-value pairs.
struct FieldVisitor<'a>(&'a mut Vec<(String, String)>);

impl Visit for FieldVisitor<'_> {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        self.0.push((field.name().to_owned(), format!("{value:?}")));
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        self.0.push((field.name().to_owned(), value.to_owned()));
    }
}

/// Visitor for recording event fields, with special handling for "message".
struct EventVisitor<'a> {
    message: &'a mut Option<String>,
    fields: &'a mut Vec<(String, String)>,
}

impl Visit for EventVisitor<'_> {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        let s = format!("{value:?}");
        if field.name() == "message" {
            *self.message = Some(s);
        } else {
            self.fields.push((field.name().to_owned(), s));
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "message" {
            *self.message = Some(value.to_owned());
        } else {
            self.fields
                .push((field.name().to_owned(), value.to_owned()));
        }
    }
}

fn format_message(
    message: Option<&str>,
    spans: &[(&str, Vec<(String, String)>)],
    fields: &[(String, String)],
) -> String {
    let mut output = String::new();

    if let Some(msg) = message {
        output.push_str(msg);
    }

    if !spans.is_empty() {
        if !output.is_empty() {
            output.push('\n');
        }
        let span_str = spans
            .iter()
            .map(|(name, fields)| {
                if fields.is_empty() {
                    (*name).to_owned()
                } else {
                    let fields_str = fields
                        .iter()
                        .map(|(k, v)| format!("{k}={v}"))
                        .collect::<Vec<_>>()
                        .join(", ");
                    format!("{name}({fields_str})")
                }
            })
            .collect::<Vec<_>>()
            .join(" / ");
        let _ = write!(output, "span: {span_str}");
    }

    for (key, value) in fields {
        if !output.is_empty() {
            output.push('\n');
        }
        let _ = write!(output, "{key}: {value}");
    }

    output
}

fn try_register_source(source: &str) -> Result<(), Error> {
    let key_path = format!("SYSTEM\\CurrentControlSet\\Services\\EventLog\\Application\\{source}");
    let key_path_wide = to_wide_string(&key_path);
    let mut hkey = windows::Win32::System::Registry::HKEY::default();

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

        let _ = RegCloseKey(hkey);
        result
    }
}

fn to_wide_string(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Creates a Windows Event Log layer with filtering from `EVENTLOG_DIRECTIVES` (default: `info`).
pub fn layer<S>(source: &str) -> Result<Layer<S>, Error>
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    Layer::new(source)
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(
        "Failed to open Event Log source '{source}': {error}. Run as admin or use: New-EventLog -LogName Application -Source \"{source}\""
    )]
    OpenSource {
        source: String,
        #[source]
        error: windows::core::Error,
    },
    #[error("Failed to create registry key: {error}")]
    CreateRegistryKey {
        #[source]
        error: windows::core::Error,
    },
    #[error("Failed to set registry value: {error}")]
    SetRegistryValue {
        #[source]
        error: windows::core::Error,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_message_with_all_parts() {
        let spans = vec![
            ("span1", vec![("id".to_owned(), "123".to_owned())]),
            ("span2", vec![]),
        ];
        let fields = vec![
            ("count".to_owned(), "42".to_owned()),
            ("name".to_owned(), "test".to_owned()),
        ];

        let output = format_message(Some("test message"), &spans, &fields);

        assert!(output.contains("test message"));
        assert!(output.contains("span: span1(id=123) / span2"));
        assert!(output.contains("count: 42"));
        assert!(output.contains("name: test"));
    }

    #[test]
    fn format_message_without_spans() {
        let output = format_message(Some("test"), &[], &[]);
        assert_eq!(output, "test");
    }

    #[test]
    fn format_message_without_message() {
        let fields = vec![("key".to_owned(), "value".to_owned())];
        let output = format_message(None, &[], &fields);
        assert_eq!(output, "key: value");
    }

    #[test]
    fn format_message_nested_spans() {
        let spans = vec![
            ("root", vec![]),
            ("middle", vec![("a".to_owned(), "1".to_owned())]),
            (
                "leaf",
                vec![
                    ("b".to_owned(), "2".to_owned()),
                    ("c".to_owned(), "3".to_owned()),
                ],
            ),
        ];

        let output = format_message(None, &spans, &[]);
        assert_eq!(output, "span: root / middle(a=1) / leaf(b=2, c=3)");
    }

    #[test]
    fn to_wide_string_null_terminated() {
        let wide = to_wide_string("test");
        assert_eq!(wide.len(), 5);
        assert_eq!(wide[4], 0);
    }

    #[test]
    fn to_wide_string_unicode() {
        let wide = to_wide_string("héllo 日本語");
        assert_eq!(*wide.last().unwrap(), 0);
        let back = String::from_utf16(&wide[..wide.len() - 1]).unwrap();
        assert_eq!(back, "héllo 日本語");
    }
}
