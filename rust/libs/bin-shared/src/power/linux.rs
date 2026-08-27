//! Suspend / resume detection for Linux via systemd-logind.

use crate::dbus;
use anyhow::Result;
use futures::{StreamExt as _, stream, stream::BoxStream};

pub(crate) async fn resume_stream() -> Result<BoxStream<'static, Result<()>>> {
    let stream = dbus::signal_stream(
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager",
        "PrepareForSleep",
    )
    .await?
    .filter(|msg| std::future::ready(is_resume(&msg.body())))
    .inspect(|_| tracing::debug!("Received DBus notification for resume from sleep"))
    .map(|_| Ok(()))
    .chain(stream::pending()); // Ensure this never ends.

    Ok(stream.boxed())
}

/// Returns `true` if the `PrepareForSleep` signal announces a resume rather than an impending
/// suspend.
///
/// `logind` emits the signal twice per sleep cycle: `true` on the way down, `false` once the system
/// is running again. Merely subscribing does not delay the suspend; that would require an inhibitor
/// lock, which we deliberately don't take.
fn is_resume(body: &zbus::message::Body) -> bool {
    matches!(body.deserialize::<bool>(), Ok(false))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_second_half_of_a_sleep_cycle_is_a_resume() {
        assert!(!is_resume(&prepare_for_sleep(true)));
        assert!(is_resume(&prepare_for_sleep(false)));
    }

    fn prepare_for_sleep(start: bool) -> zbus::message::Body {
        zbus::Message::signal(
            "/org/freedesktop/login1",
            "org.freedesktop.login1.Manager",
            "PrepareForSleep",
        )
        .expect("Should be able to build a signal")
        .build(&(start,))
        .expect("Should be able to serialise a bool")
        .body()
    }
}
