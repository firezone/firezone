//! Heavily inspired from https://github.com/Actyx/tracing-android/blob/master/src/android.rs.

use std::{
    ffi::{CStr, CString},
    io::{self, BufWriter},
};
use tracing::Level;

const LOGGING_MSG_MAX_LEN: usize = 4000;

pub(crate) struct MakeWriter {
    tag: CString,
}

pub(crate) struct Writer {
    level: Level,
    tag: CString,
}

impl MakeWriter {
    pub(crate) fn new(tag: &'static str) -> Self {
        Self {
            tag: CString::new(tag).expect("tag must not contain nul-byte"),
        }
    }

    fn make_writer_for_level(&self, level: Level) -> BufWriter<Writer> {
        let inner = Writer {
            level,
            tag: self.tag.clone(),
        };

        BufWriter::with_capacity(LOGGING_MSG_MAX_LEN, inner)
    }
}

impl tracing_subscriber::fmt::MakeWriter<'_> for MakeWriter {
    type Writer = BufWriter<Writer>;

    fn make_writer(&self) -> Self::Writer {
        self.make_writer_for_level(Level::INFO)
    }

    fn make_writer_for(&self, meta: &tracing::Metadata<'_>) -> Self::Writer {
        self.make_writer_for_level(*meta.level())
    }
}

impl io::Write for Writer {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let written = buf.len().min(LOGGING_MSG_MAX_LEN);

        let msg = &buf[..written];
        let msg = CString::new(msg.to_vec())?;

        android_log(self.level, self.tag.as_c_str(), &msg);

        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(target_os = "android")]
fn android_log(level: Level, tag: &CStr, msg: &CStr) {
    let prio = match level {
        Level::WARN => android_log_sys::LogPriority::WARN,
        Level::INFO => android_log_sys::LogPriority::INFO,
        Level::DEBUG => android_log_sys::LogPriority::DEBUG,
        Level::ERROR => android_log_sys::LogPriority::ERROR,
        Level::TRACE => android_log_sys::LogPriority::VERBOSE,
    };

    // Safety: FFI calls are unsafe.
    unsafe {
        android_log_sys::__android_log_write(
            prio as android_log_sys::c_int,
            tag.as_ptr() as *const android_log_sys::c_char,
            msg.as_ptr() as *const android_log_sys::c_char,
        )
    };
}

#[cfg(not(target_os = "android"))]
fn android_log(_: Level, _: &CStr, _: &CStr) {
    unimplemented!("Logger is not meant to be used in non-Android environments")
}
