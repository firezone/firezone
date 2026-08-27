//! Suspend / resume detection for Windows.

use anyhow::{Context as _, Result};
use futures::{StreamExt as _, stream, stream::BoxStream};
use std::{ffi::c_void, sync::Mutex};
use tokio::sync::broadcast::{self, error::RecvError};
use windows::Win32::{
    Foundation::{ERROR_SUCCESS, HANDLE},
    System::Power::{DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS, PowerRegisterSuspendResumeNotification},
    UI::WindowsAndMessaging::{DEVICE_NOTIFY_CALLBACK, PBT_APMRESUMEAUTOMATIC},
};

/// The sender half of the process-wide resume notifications, once we have registered for them.
static RESUME_TX: Mutex<Option<&'static broadcast::Sender<()>>> = Mutex::new(None);

#[expect(
    clippy::unused_async,
    reason = "Must match the Linux implementation, which needs to connect to DBus."
)]
pub(crate) async fn resume_stream() -> Result<BoxStream<'static, Result<()>>> {
    let rx = subscribe()?;

    let stream = stream::unfold(rx, |mut rx| async move {
        match rx.recv().await {
            Ok(()) => Some((Ok(()), rx)),
            // We only care that we resumed, not how many resumes we missed.
            Err(RecvError::Lagged(_)) => Some((Ok(()), rx)),
            Err(RecvError::Closed) => None,
        }
    })
    .inspect(|_| tracing::debug!("Received power notification for resume from sleep"))
    .chain(stream::pending()); // Ensure this never ends.

    Ok(stream.boxed())
}

/// Registers for suspend / resume notifications on first use and subscribes to them.
///
/// The registration is process-wide and never cancelled. Unlike `CancelMibChangeNotify2`, which
/// blocks until any in-flight callback has returned, `PowerUnregisterSuspendResumeNotification`
/// makes no such promise, so the context we hand to the OS has to outlive the process.
fn subscribe() -> Result<broadcast::Receiver<()>> {
    let mut registered = RESUME_TX.lock().unwrap_or_else(|e| e.into_inner());

    if let Some(tx) = *registered {
        return Ok(tx.subscribe());
    }

    let (tx, rx) = broadcast::channel(1);
    let tx = Box::new(tx);

    let mut params = DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS {
        Callback: Some(suspend_resume_callback),
        Context: std::ptr::from_ref(&*tx) as *mut c_void,
    };
    let mut registration = std::ptr::null_mut();

    // SAFETY: `params` only needs to live for the duration of the call; the OS copies what it
    // needs. `registration` is written by the call and unused afterwards, as we never unregister.
    unsafe {
        PowerRegisterSuspendResumeNotification(
            DEVICE_NOTIFY_CALLBACK,
            HANDLE(std::ptr::from_mut(&mut params).cast()),
            &mut registration,
        )
    }
    .ok()
    .context("Failed to register for suspend / resume notifications")?; // On failure the OS never got our pointer, so `tx` is dropped here.

    *registered = Some(Box::leak(tx));

    Ok(rx)
}

/// Runs on a Windows-managed thread, so keep it minimal: just wake the notifier.
///
/// This is a safe `extern "system" fn` (it coerces to the unsafe callback pointer the OS
/// expects), keeping the only `unsafe` to the single pointer dereference below.
extern "system" fn suspend_resume_callback(
    ctx: *const c_void,
    event_type: u32,
    _setting: *const c_void,
) -> u32 {
    // `PBT_APMRESUMEAUTOMATIC` is delivered on every resume, whereas `PBT_APMRESUMESUSPEND` only
    // follows it if the user is present. Matching just this one gives us exactly one notification
    // per resume.
    if event_type != PBT_APMRESUMEAUTOMATIC {
        return ERROR_SUCCESS.0;
    }

    // SAFETY: `ctx` is the pointer we passed to `PowerRegisterSuspendResumeNotification`: a
    // deliberately leaked `broadcast::Sender` that outlives the process.
    let tx = unsafe { &*ctx.cast::<broadcast::Sender<()>>() };

    // A failed send just means nobody is listening right now.
    let _ = tx.send(());

    ERROR_SUCCESS.0
}
