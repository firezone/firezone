use std::fmt::Write as _;
use std::sync::{Arc, Mutex};

use anyhow::{Context as _, Result};
use tracing::field::{Field, Visit};
use tracing::span::Attributes;
use tracing::{Event, Id, Level, Subscriber};
use tracing_subscriber::layer::Context;
use tracing_subscriber::registry::LookupSpan;
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

/// Creates a Windows Event Log layer for the specified source.
pub fn layer(source: &str) -> Result<Layer> {
    Layer::new(source)
}

/// A tracing layer that writes events to the Windows Event Log.
///
/// On non-Windows platforms, this does nothing.
pub struct Layer {
    handle: Arc<EventSourceHandle>,
}

impl Layer {
    fn new(source: &str) -> Result<Self> {
        let _ = try_register_source(source);

        let source_wide = to_wide_string(source);
        let handle = unsafe { RegisterEventSourceW(PCWSTR::null(), PCWSTR(source_wide.as_ptr())) }
            .with_context(|| format!("Failed to open Event Log source '{source}': Run as admin or use: New-EventLog -LogName Application -Source \"{source}\""))?;

        Ok(Self {
            handle: Arc::new(EventSourceHandle::new(handle)),
        })
    }
}

impl<S> tracing_subscriber::Layer<S> for Layer
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

        // Collect all span fields
        if let Some(scope) = ctx.event_scope(event) {
            for span in scope.from_root() {
                if let Some(span_fields) = span.extensions().get::<SpanFields>() {
                    fields.extend(span_fields.fields.iter().cloned());
                }
            }
        }

        let output = format_message(message.as_deref(), &fields);
        self.handle.report_event(event_type, event_id, &output);
    }
}

/// Storage for span fields.
#[derive(Default)]
struct SpanFields {
    fields: Vec<(String, String)>,
}

/// Visitor for recording fields as key-value pairs.
struct FieldVisitor<'a>(&'a mut Vec<(String, String)>);

/// Visitor for recording event fields, with special handling for "message".
struct EventVisitor<'a> {
    message: &'a mut Option<String>,
    fields: &'a mut Vec<(String, String)>,
}

impl Visit for FieldVisitor<'_> {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        self.0.push((field.name().to_owned(), format!("{value:?}")));
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        self.0.push((field.name().to_owned(), value.to_owned()));
    }
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

fn format_message(message: Option<&str>, fields: &[(String, String)]) -> String {
    let mut output = String::new();

    if let Some(msg) = message {
        output.push_str(msg);
    }

    // Append all fields at the end
    for (key, value) in fields {
        if !output.is_empty() {
            output.push(' ');
        }
        let _ = write!(output, "{key}={value}");
    }

    output
}

fn try_register_source(source: &str) -> Result<()> {
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
        .context("Failed to create registry key")?;

        let result = (|| {
            RegSetValueExW(
                hkey,
                w!("TypesSupported"),
                Some(0),
                REG_DWORD,
                Some(TYPES_SUPPORTED.to_le_bytes().as_slice()),
            )
            .ok()
            .context("Failed to set registry value")?;

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
            .context("Failed to set registry value")?;

            Ok(())
        })();

        let _ = RegCloseKey(hkey);
        result
    }
}

fn to_wide_string(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_message_with_all_parts() {
        let fields = vec![
            ("id".to_owned(), "123".to_owned()),
            ("count".to_owned(), "42".to_owned()),
            ("name".to_owned(), "test".to_owned()),
        ];

        let output = format_message(Some("test message"), &fields);

        assert_eq!(output, "test message id=123 count=42 name=test");
    }

    #[test]
    fn format_message_without_fields() {
        let output = format_message(Some("test"), &[]);

        assert_eq!(output, "test");
    }

    #[test]
    fn format_message_without_message() {
        let fields = vec![("key".to_owned(), "value".to_owned())];

        let output = format_message(None, &fields);

        assert_eq!(output, "key=value");
    }

    #[test]
    fn format_message_multiple_fields() {
        let fields = vec![
            ("a".to_owned(), "1".to_owned()),
            ("b".to_owned(), "2".to_owned()),
            ("c".to_owned(), "3".to_owned()),
        ];

        let output = format_message(None, &fields);

        assert_eq!(output, "a=1 b=2 c=3");
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
