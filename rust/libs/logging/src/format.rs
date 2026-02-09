//! Defines our custom event format.
//!
//! Inspired by `Compact` in <https://github.com/tokio-rs/tracing/blob/tracing-subscriber-0.3.18/tracing-subscriber/src/fmt/format/mod.rs>.

use std::{fmt, io, num::NonZeroU8};

use nu_ansi_term::{Color, Style};
use time::format_description::well_known::{
    Iso8601,
    iso8601::{Config, EncodedConfig, TimePrecision},
};
use tracing::{Event, Level, Subscriber};
use tracing_log::NormalizeEvent as _;
use tracing_subscriber::{
    fmt::{FmtContext, FormatEvent, FormatFields, FormattedFields, format::Writer},
    registry::LookupSpan,
};

/// A custom [`FormatEvent`] implementation for [`tracing_subscriber`] that renders compact, yet informative logs.
///
/// Most importantly, we log:
///
/// - ISO8601 timestamp
/// - The log level
/// - The log target
/// - The actual message
/// - All fields, including the fields of all active spans
///
/// Most importantly, the actual span-name is not logged.
pub struct Format {
    time: bool,
    level: bool,
}

impl Format {
    pub fn new() -> Self {
        Self {
            time: true,
            level: true,
        }
    }

    pub fn without_timestamp(self) -> Self {
        Self {
            time: false,
            ..self
        }
    }

    pub fn without_level(self) -> Self {
        Self {
            level: false,
            ..self
        }
    }
}

impl Default for Format {
    fn default() -> Self {
        Self::new()
    }
}

const TIMESTAMP_FORMAT_CONFIG: EncodedConfig = Config::DEFAULT
    .set_time_precision(TimePrecision::Second {
        decimal_digits: Some(NonZeroU8::new(3).expect("3 > 0")),
    })
    .encode();

impl<S, N> FormatEvent<S, N> for Format
where
    S: Subscriber + for<'a> LookupSpan<'a>,
    N: for<'a> FormatFields<'a> + 'static,
{
    fn format_event(
        &self,
        ctx: &FmtContext<'_, S, N>,
        mut writer: Writer<'_>,
        event: &Event<'_>,
    ) -> fmt::Result {
        let normalized_meta = event.normalized_metadata();
        let meta = normalized_meta.as_ref().unwrap_or_else(|| event.metadata());

        if self.time {
            if writer.has_ansi_escapes() {
                let style = Style::new().dimmed();
                write!(writer, "{}", style.prefix())?;

                ::time::OffsetDateTime::now_utc()
                    .format_into(
                        &mut IoWriteAdapter::new(&mut writer),
                        &Iso8601::<TIMESTAMP_FORMAT_CONFIG>,
                    )
                    .map_err(|_| fmt::Error)?;

                write!(writer, "{} ", style.suffix())?;
            } else {
                ::time::OffsetDateTime::now_utc()
                    .format_into(
                        &mut IoWriteAdapter::new(&mut writer),
                        &Iso8601::<TIMESTAMP_FORMAT_CONFIG>,
                    )
                    .map_err(|_| fmt::Error)?;

                writer.write_char(' ')?;
            }
        }

        if self.level {
            let fmt_level = FmtLevel::new(meta.level(), writer.has_ansi_escapes());

            write!(writer, "{fmt_level} ")?;
        }

        let dimmed = if writer.has_ansi_escapes() {
            Style::new().dimmed()
        } else {
            Style::new()
        };

        write!(
            writer,
            "{}{}",
            dimmed.paint(meta.target()),
            dimmed.paint(":")
        )?;
        writer.write_char(' ')?;

        ctx.format_fields(writer.by_ref(), event)?;

        for span in ctx
            .event_scope()
            .into_iter()
            .flat_map(tracing_subscriber::registry::Scope::from_root)
        {
            let exts = span.extensions();
            if let Some(fields) = exts.get::<FormattedFields<N>>()
                && !fields.is_empty()
            {
                write!(writer, " {}", fields.fields)?;
            }
        }
        writeln!(writer)
    }
}

/// An adapter to go from [`io::Write`] to [`fmt::Write`] that assumes all bytes are UTF-8 strings.
struct IoWriteAdapter<'a> {
    fmt_write: &'a mut dyn fmt::Write,
}

impl<'a> IoWriteAdapter<'a> {
    fn new(fmt_write: &'a mut dyn fmt::Write) -> Self {
        Self { fmt_write }
    }
}

impl io::Write for IoWriteAdapter<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let s = match std::str::from_utf8(buf) {
            Ok(s) => s,
            Err(e) => return Err(io::Error::other(e)),
        };
        self.fmt_write.write_str(s).map_err(io::Error::other)?;

        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct FmtLevel<'a> {
    level: &'a Level,
    ansi: bool,
}

impl<'a> FmtLevel<'a> {
    pub(crate) fn new(level: &'a Level, ansi: bool) -> Self {
        Self { level, ansi }
    }
}

const TRACE_STR: &str = "TRACE";
const DEBUG_STR: &str = "DEBUG";
const INFO_STR: &str = " INFO";
const WARN_STR: &str = " WARN";
const ERROR_STR: &str = "ERROR";

impl fmt::Display for FmtLevel<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.ansi {
            match *self.level {
                Level::TRACE => write!(f, "{}", Color::Purple.paint(TRACE_STR)),
                Level::DEBUG => write!(f, "{}", Color::Blue.paint(DEBUG_STR)),
                Level::INFO => write!(f, "{}", Color::Green.paint(INFO_STR)),
                Level::WARN => write!(f, "{}", Color::Yellow.paint(WARN_STR)),
                Level::ERROR => write!(f, "{}", Color::Red.paint(ERROR_STR)),
            }
        } else {
            match *self.level {
                Level::TRACE => f.pad(TRACE_STR),
                Level::DEBUG => f.pad(DEBUG_STR),
                Level::INFO => f.pad(INFO_STR),
                Level::WARN => f.pad(WARN_STR),
                Level::ERROR => f.pad(ERROR_STR),
            }
        }
    }
}
