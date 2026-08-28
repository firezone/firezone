//! Notifications about the system suspending and resuming.

use anyhow::Result;
use futures::{
    Stream, StreamExt as _,
    stream::{self, BoxStream},
};
use std::{
    pin::Pin,
    task::{Context, Poll},
};

#[cfg(target_os = "linux")]
#[path = "power/linux.rs"]
mod imp;

#[cfg(target_os = "windows")]
#[path = "power/windows.rs"]
mod imp;

#[cfg(target_os = "macos")]
#[path = "power/macos.rs"]
mod imp;

/// Listens for the system resuming from sleep.
///
/// A resume invalidates most of what we know about the network: our peers have torn down their end
/// of the connection, NAT bindings have expired and we may have come back on a different network.
/// Callers are expected to reset their session upon notification.
///
/// Suspends are deliberately not reported. We have nothing to do before going to sleep and on most
/// platforms we wouldn't reliably get the chance to do it anyway.
pub async fn new_resume_notifier() -> Result<ResumeNotifier> {
    Ok(ResumeNotifier(imp::resume_stream().await?))
}

/// A stream of "the system just resumed" notifications.
///
/// Implements [`Default`] as a no-op stream so callers can use `.unwrap_or_default()` to
/// gracefully degrade when the notifier fails to initialise.
pub struct ResumeNotifier(BoxStream<'static, Result<()>>);

impl Default for ResumeNotifier {
    fn default() -> Self {
        Self(stream::pending().boxed())
    }
}

impl Stream for ResumeNotifier {
    type Item = Result<()>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        self.0.as_mut().poll_next(cx)
    }
}
