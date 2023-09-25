use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::{fs, io};

pub fn new(directory: PathBuf, name: String) -> (Appender, Handle) {
    let inner = Arc::new(Mutex::new(Inner { directory, name }));
    let appender = Appender {
        inner: inner.clone(),
    };
    let handle = Handle { inner };

    (appender, handle)
}

#[derive(Debug)]
pub struct Appender {
    inner: Arc<Mutex<Inner>>,
}
#[derive(Clone, Debug)]
pub struct Handle {
    inner: Arc<Mutex<Inner>>,
}

impl Handle {
    /// Rolls over to a new file.
    ///
    /// Returns the path to the now unused, previous log file.
    pub fn roll_to_new_file(&self) -> PathBuf {
        todo!()
    }
}

#[derive(Debug)]
struct Inner {
    directory: PathBuf,
    name: String,
}

impl io::Write for Appender {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        todo!()
    }

    fn flush(&mut self) -> io::Result<()> {
        todo!()
    }
}

// Copied from `tracing-appender/src/rolling.rs`.
fn create_writer(directory: &str, filename: &str) -> io::Result<File> {
    let path = Path::new(directory).join(filename);
    let mut open_options = OpenOptions::new();
    open_options.append(true).create(true);

    let new_file = open_options.open(path.as_path());
    if new_file.is_err() {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
            return open_options.open(path);
        }
    }

    new_file
}
