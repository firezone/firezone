//! A library for the privileged tunnel process for a Linux Firezone Client
//!
//! This is built both standalone and as part of the GUI package. Building it
//! standalone is faster and skips all the GUI dependencies. We can use that build for
//! CLI use cases.
//!
//! Building it as a binary within the `gui-client` package allows the
//! Tauri deb bundler to pick it up easily.
//! Otherwise we would just make it a normal binary crate.

use anyhow::Result;
use serde::Serialize;
use std::path::PathBuf;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "linux")]
pub use linux::run;

#[cfg(target_os = "windows")]
mod windows {
    use clap::Parser;

    pub async fn run() -> anyhow::Result<()> {
        let _cli = super::Cli::parse();
        Ok(())
    }
}

#[cfg(target_os = "windows")]
pub use windows::run;

#[derive(clap::Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    /// Don't act as a CLI Client, act as a tunnel for a GUI Client
    ///
    /// This is not supported and will change in the near future.
    #[arg(long, hide = true, default_value = "false")]
    pub act_as_tunnel: bool,

    #[arg(
        short = 'u',
        long,
        hide = true,
        env = "FIREZONE_API_URL",
        default_value = "wss://api.firezone.dev"
    )]
    pub api_url: url::Url,

    /// Token generated by the portal to authorize websocket connection.

    // TODO: It isn't good for security to pass the token as a CLI arg.
    // If we pass it as an env var, we should remove it immediately so that
    // other processes don't see it. Reading it from a file is probably safest.
    #[arg(env = "FIREZONE_TOKEN")]
    pub token: Option<String>,

    /// Identifier used by the portal to identify and display the device.

    // AKA `device_id` in the Windows and Linux GUI clients
    // Generated automatically if not provided
    #[arg(short = 'i', long, env = "FIREZONE_ID")]
    pub firezone_id: Option<String>,

    /// File logging directory. Should be a path that's writeable by the current user.
    #[arg(short, long, env = "LOG_DIR")]
    log_dir: Option<PathBuf>,

    /// Maximum length of time to retry connecting to the portal if we're having internet issues or
    /// it's down. Accepts human times. e.g. "5m" or "1h" or "30d".
    #[arg(short, long, env = "MAX_PARTITION_TIME")]
    max_partition_time: Option<humantime::Duration>,
}

// Copied from <https://github.com/firezone/subzone>

/// Reads a message from an async reader, with a 32-bit LE length prefix
// Dead on Windows temporarily
#[allow(dead_code)]
async fn read_ipc_msg<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf).await?;
    let len = u32::from_le_bytes(len_buf);
    let len = usize::try_from(len)?;
    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf).await?;
    Ok(buf)
}

/// Encodes a message as JSON and writes it to an async writer, with a 32-bit LE length prefix
///
/// TODO: Why does this one take `T` and `read_ipc_msg` doesn't?
// Dead on Windows temporarily
#[allow(dead_code)]
async fn write_ipc_msg<W: AsyncWrite + Unpin, T: Serialize>(writer: &mut W, msg: &T) -> Result<()> {
    let buf = serde_json::to_string(msg)?;
    let len = u32::try_from(buf.len())?.to_le_bytes();
    writer.write_all(&len).await?;
    writer.write_all(buf.as_bytes()).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    #[cfg(target_os = "windows")]
    mod windows {
        use crate::{read_ipc_msg, write_ipc_msg};

        const MESSAGE_ONE: &str = "message one";

        #[tokio::test]
        async fn ipc_windows() {
            // Round-trip a message to avoid dead code warnings
            let mut buffer = vec![];

            write_ipc_msg(&mut buffer, &MESSAGE_ONE.to_string())
                .await
                .unwrap();

            let mut cursor = std::io::Cursor::new(buffer);
            let v = read_ipc_msg(&mut cursor).await.unwrap();
            let s = String::from_utf8(v).unwrap();
            let decoded: String = serde_json::from_str(&s).unwrap();
            assert_eq!(decoded, MESSAGE_ONE);

            // TODO: Windows process splitting
            // <https://github.com/firezone/firezone/issues/3712>
        }
    }
}
