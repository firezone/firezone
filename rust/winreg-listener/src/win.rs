use anyhow::{Context as _, Result};
use futures::FutureExt as _;
use std::{ffi::c_void, ops::Deref, path::Path, pin::pin};
use tokio::{
    sync::{mpsc, oneshot},
    task::LocalSet,
};
use windows::Win32::{
    Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE},
    System::Registry,
    System::Threading::{
        CreateEventA, INFINITE, RegisterWaitForSingleObject, UnregisterWaitEx,
        WT_EXECUTEINWAITTHREAD,
    },
};
use winreg::RegKey;

pub fn worker_thread(
    tokio_handle: tokio::runtime::Handle,
    tx: super::NotifySender,
    stopper_rx: oneshot::Receiver<()>,
    keys: &[RegKey],
) -> Result<()> {
    let local = LocalSet::new();
    let task = local.run_until(async move {
        let mut listener_4 = Listener::new(key_ipv4)?;
        let mut listener_6 = Listener::new(key_ipv6)?;

        // Notify once we start listening, to be consistent with other notifiers. This is intended to cover gaps during startup, e.g.:
        //
        // 1. Caller records network state / DNS resolvers
        // 2. Caller creates a notifier
        // 3. While we're setting up the notifier, the network or DNS state changes
        // 4. The caller is now stuck on a stale state until the first notification comes through.

        tx.notify()?;

        let mut stop = pin!(stopper_rx.fuse());
        loop {
            let mut fut_4 = pin!(listener_4.notified().fuse());
            let mut fut_6 = pin!(listener_6.notified().fuse());
            futures::select! {
                _ = stop => break,
                _ = fut_4 => tx.notify()?,
                _ = fut_6 => tx.notify()?,
            }
        }

        if let Err(e) = listener_4.close() {
            tracing::error!("Error while closing IPv4 DNS listener: {e:#}");
        }
        if let Err(e) = listener_6.close() {
            tracing::error!("Error while closing IPv6 DNS listener: {e:#}");
        }

        Ok(())
    });

    tokio_handle.block_on(task)
}

/// Listens to one registry key for changes. Callers should await `notified`.
struct Listener {
    key: winreg::RegKey,
    // Rust never uses `tx` again, but the C callback borrows it. So it must live as long
    // as Listener, and then be dropped after the C callback is cancelled and any
    // ongoing callback finishes running.
    //
    // We box it here to avoid this sequence:
    // - `Listener::new` called, pointer to `tx` passed to `RegisterWaitForSingleObject`
    // - `Listener` and `tx` move
    // - The callback fires, using the now-invalid previous location of `tx`
    //
    // So don't ever do `self._tx = $ANYTHING` after `new`, it'll break the callback.
    _tx: Box<mpsc::Sender<()>>,
    rx: mpsc::Receiver<()>,
    // Separated so that multiple `drop` calls are safe and wont' panic
    inner: Option<ListenerInner>,
}

struct ListenerInner {
    /// A handle representing our registered callback from `RegisterWaitForSingleObject`
    ///
    /// This doesn't get signalled, it's just used so we can unregister and stop the
    /// callbacks gracefully when dropping the `Listener`.
    wait_handle: HANDLE,
    /// An event that's 'signalled' when the registry key changes
    ///
    /// `RegNotifyChangeKeyValue` can't call a callback directly, so it signals this
    /// event, and we use `RegisterWaitForSingleObject` to adapt that signal into
    /// a C callback.
    event: HANDLE,
}

impl Listener {
    pub(crate) fn new(key: winreg::RegKey) -> Result<Self> {
        let (tx, rx) = mpsc::channel(1);
        let tx = Box::new(tx);
        let tx_ptr: *const _ = tx.deref();
        let event = unsafe { CreateEventA(None, false, false, None) }?;
        let mut wait_handle = HANDLE::default();

        // The docs say that `RegisterWaitForSingleObject` uses "a worker thread" from
        // "the thread pool".
        // Raymond Chen, who is an authority on Windows internals, says RegisterWaitForSingleObject
        // does multiple waits on the same worker thread internally:
        // <https://devblogs.microsoft.com/oldnewthing/20081117-00/?p=20183>
        // There is a different function in the CLR called `RegisterWaitForSingleObject`,
        // so he might be talking about that.
        // If he's not, then we're invisibly tying up two worker threads. Can't help it.

        // SAFETY: It's complicated.
        // The callback here can cause a lot of problems. We box the `Sender` object
        // so its memory address won't change.
        // We don't use an `Arc` because sending is already `&self`, and
        // the callback has no way to free an `Arc`, since we will always cancel the callback
        // before it fires when the `Listener` drops.
        // When we call `UnregisterWaitEx` later, we wait for all callbacks to finish running
        // before we drop everything, to prevent the callback from seeing a dangling pointer.
        unsafe {
            RegisterWaitForSingleObject(
                &mut wait_handle,
                event,
                Some(callback),
                Some(tx_ptr as *const _),
                INFINITE,
                WT_EXECUTEINWAITTHREAD,
            )
        }?;

        let inner = ListenerInner { wait_handle, event };
        let mut that = Self {
            key,
            _tx: tx,
            rx,
            inner: Some(inner),
        };
        that.register_callback()?;

        Ok(that)
    }

    /// Returns when the registry key has changed
    ///
    /// This is `&mut self` because calling `register_callback` twice
    /// before the callback fires would cause a resource leak.
    /// Cancel-safety: Yes. <https://docs.rs/tokio/latest/tokio/macro.select.html#cancellation-safety>
    pub(crate) async fn notified(&mut self) -> Result<()> {
        // We use a particular order here because I initially assumed
        // `RegNotifyChangeKeyValue` has a gap in this sequence:
        // - RegNotifyChangeKeyValue
        // - (Value changes)
        // - (We catch the notification and read the DNS)
        // - (Value changes again)
        // - RegNotifyChangeKeyValue
        // - (The second change is dropped)
        //
        // But Windows seems to actually do some magic so that the 2nd
        // call of `RegNotifyChangeKeyValue` signals immediately, even though there
        // was no registered notification when the value changed.
        // See the unit test below.
        //
        // This code is ordered to protect against such a gap, by returning to the
        // caller only when we are registered, but it's redundant.
        self.rx.recv().await.context("`Listener` is closing down")?;
        self.register_callback()
            .context("`register_callback` failed")?;

        Ok(())
    }

    // Be careful with this, if you register twice before the callback fires,
    // it will leak some resource.
    // <https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regnotifychangekeyvalue#remarks>
    //
    // > Each time a process calls RegNotifyChangeKeyValue with the same set of parameters, it establishes another wait operation, creating a resource leak. Therefore, check that you are not calling RegNotifyChangeKeyValue with the same parameters until the previous wait operation has completed.
    fn register_callback(&mut self) -> Result<()> {
        let inner = self
            .inner
            .as_ref()
            .context("Can't register callback after dropped")?;
        let key_handle = Registry::HKEY(self.key.raw_handle() as *mut c_void);
        let notify_flags = Registry::REG_NOTIFY_CHANGE_NAME
            | Registry::REG_NOTIFY_CHANGE_LAST_SET
            | Registry::REG_NOTIFY_THREAD_AGNOSTIC;
        // Ask Windows to signal our event once when anything inside this key changes.
        // We can't ask for repeated signals.
        unsafe {
            Registry::RegNotifyChangeKeyValue(
                key_handle,
                true,
                notify_flags,
                Some(inner.event),
                true,
            )
        }
        .ok()
        .context("`RegNotifyChangeKeyValue` failed")?;
        Ok(())
    }

    fn close(mut self) -> Result<()> {
        self.close_dont_drop()
    }

    /// Close without consuming `self`
    ///
    /// This must be factored out so that we can have both:
    /// - `close` which consumes `self` and returns a `Result` for error bubbling
    /// - `drop` which does not consume `self` and does not bubble errors, but which runs even if we forget to call `close`
    fn close_dont_drop(&mut self) -> Result<()> {
        if let Some(inner) = self.inner.take() {
            unsafe { UnregisterWaitEx(inner.wait_handle, Some(INVALID_HANDLE_VALUE)) }
                .context("Should be able to `UnregisterWaitEx` in the DNS change listener")?;
            unsafe { CloseHandle(inner.event) }
                .context("Should be able to `CloseHandle` in the DNS change listener")?;
        }
        Ok(())
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.close_dont_drop()
            .expect("Should be able to close DNS listener");
    }
}

// SAFETY: The `Sender` should be alive, because we only `Drop` it after waiting
// for any run of this callback to finish.
// This function runs on a worker thread in a Windows-managed thread pool where
// many API calls are illegal, so try not to do anything in here. Right now
// all we do is wake up our Tokio task.
unsafe extern "system" fn callback(ctx: *mut c_void, _: bool) {
    let tx = unsafe { &*(ctx as *const mpsc::Sender<()>) };
    // It's not a problem if sending fails. It either means the `Listener`
    // is closing down, or it's already been notified.
    tx.try_send(()).ok();
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::{
        Foundation::WAIT_OBJECT_0,
        System::Threading::{ResetEvent, WaitForSingleObject},
    };

    fn event_is_signaled(event: HANDLE) -> bool {
        unsafe { WaitForSingleObject(event, 0) == WAIT_OBJECT_0 }
    }

    fn reg_notify(key: &winreg::RegKey, event: HANDLE) {
        assert!(!event_is_signaled(event));
        let notify_flags = Registry::REG_NOTIFY_CHANGE_NAME
            | Registry::REG_NOTIFY_CHANGE_LAST_SET
            | Registry::REG_NOTIFY_THREAD_AGNOSTIC;
        let key_handle = Registry::HKEY(key.raw_handle() as *mut c_void);
        unsafe {
            Registry::RegNotifyChangeKeyValue(key_handle, true, notify_flags, Some(event), true)
        }
        .ok()
        .expect("`RegNotifyChangeKeyValue` failed");
    }

    fn set_reg_value(key: &winreg::RegKey, val: u32) {
        key.set_value("some_key", &val)
            .expect("setting registry value `{val}` failed");
    }

    fn reset_event(event: HANDLE) {
        unsafe { ResetEvent(event) }.expect("`ResetEvent` failed");
        assert!(!event_is_signaled(event));
    }

    #[test]
    fn registry() {
        let flags = winreg::enums::KEY_NOTIFY | winreg::enums::KEY_WRITE;
        let key_path = Path::new("Software")
            .join("dev.firezone.client")
            .join("test_CZD3JHFS");
        let (key, _disposition) = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
            .create_subkey_with_flags(&key_path, flags)
            .expect("`open_subkey_with_flags` failed");

        let event =
            unsafe { CreateEventA(None, false, false, None) }.expect("`CreateEventA` failed");

        // Registering the notify alone does not signal the event
        reg_notify(&key, event);
        assert!(!event_is_signaled(event));

        // Setting the value after we've registered does
        set_reg_value(&key, 0);
        assert!(event_is_signaled(event));

        // Do that one more time to prove it wasn't a fluke
        reset_event(event);
        reg_notify(&key, event);
        assert!(!event_is_signaled(event));

        set_reg_value(&key, 500);
        assert!(event_is_signaled(event));

        // I thought there was a gap here, but there's actually not -
        // If we get the notification, then the value changes, then we re-register,
        // we immediately get notified again. I'm not sure how Windows does this.
        // Maybe it's storing the state with our regkey handle instead of with the
        // wait operation. This is convenient but it's confusing since the docs don't
        // make it clear. I'll leave the workaround in the main code.
        reset_event(event);
        set_reg_value(&key, 1000);
        assert!(!event_is_signaled(event));
        reg_notify(&key, event);
        // This is the part I was wrong about
        assert!(event_is_signaled(event));

        // Signal normally one more time
        reset_event(event);
        reg_notify(&key, event);
        set_reg_value(&key, 2000);
        assert!(event_is_signaled(event));

        // Close the handle before the notification goes off
        reset_event(event);
        reg_notify(&key, event);
        unsafe { CloseHandle(event) }.expect("`CloseHandle` failed");
        let _ = event;

        // Setting the value shouldn't break anything or crash here.
        set_reg_value(&key, 3000);

        winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
            .delete_subkey_all(&key_path)
            .expect("Should be able to delete test key");
    }
}
