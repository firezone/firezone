pub(crate) use imp::is_normal_user;

#[cfg(target_os = "linux")]
mod imp {
    use crate::client::gui::Error;
    use anyhow::{Context as _, Result};
    use firezone_headless_client::FIREZONE_GROUP;

    /// Returns true if we're running without root privileges
    ///
    /// Everything that needs root / admin powers happens in the IPC services,
    /// so for security and practicality reasons the GUIs must be non-root.
    /// (In Linux by default a root GUI app barely works at all)
    pub(crate) fn is_normal_user() -> Result<bool, Error> {
        // Must use `eprintln` here because `tracing` won't be initialized yet.
        let user = std::env::var("USER").context("USER env var should be set")?;
        if user == "root" {
            return Ok(false);
        }

        let fz_gid = firezone_group()?.gid;
        let groups = nix::unistd::getgroups().context("`nix::unistd::getgroups`")?;
        if !groups.contains(&fz_gid) {
            return Err(Error::UserNotInFirezoneGroup);
        }

        Ok(true)
    }

    fn firezone_group() -> Result<nix::unistd::Group> {
        let group = nix::unistd::Group::from_name(FIREZONE_GROUP)
            .context("can't get group by name")?
            .with_context(|| format!("`{FIREZONE_GROUP}` group must exist on the system"))?;
        Ok(group)
    }
}

// Stub only
#[cfg(target_os = "macos")]
mod imp {
    /// Placeholder for cargo check on macOS
    pub(crate) fn is_normal_user() -> anyhow::Result<bool, crate::client::gui::Error> {
        Ok(true)
    }
}

#[cfg(target_os = "windows")]
mod imp {
    use crate::client::gui::Error;
    use anyhow::{Context as _, Result};
    use std::{ffi::c_void, mem::size_of};
    use windows::Win32::{
        Foundation::{CloseHandle, HANDLE},
        Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY},
        System::Threading::{GetCurrentProcess, OpenProcessToken},
    };

    // Returns true on Windows
    ///
    /// On Windows, checking for elevation is complicated,
    /// so it just always returns true. The Windows GUI does work correctly even if
    /// elevated, so we should warn users that it doesn't need elevation, but it's
    /// not a show-stopper if they accidentally "Run as admin".
    #[allow(clippy::unnecessary_wraps)]
    pub(crate) fn is_normal_user() -> Result<bool, Error> {
        let token = ProcessToken::our_process().map_err(Error::Other)?;
        let elevated = token.is_elevated().map_err(Error::Other)?;
        Ok(!elevated)
    }

    // https://stackoverflow.com/questions/8046097/how-to-check-if-a-process-has-the-administrative-rights/8196291#8196291
    struct ProcessToken {
        inner: HANDLE,
    }

    impl ProcessToken {
        fn our_process() -> Result<Self> {
            // SAFETY: Calling C APIs is unsafe
            // `GetCurrentProcess` returns a pseudo-handle which does not need to be closed.
            // Docs say nothing about thread safety. <https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getcurrentprocess>
            let our_proc = unsafe { GetCurrentProcess() };
            let mut inner = HANDLE::default();
            // SAFETY: We just created `inner`, and moving a `HANDLE` is safe.
            // We assume that if `OpenProcessToken` fails, we don't need to close the `HANDLE`.
            // Docs say nothing about threads or safety: <https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocesstoken>
            unsafe { OpenProcessToken(our_proc, TOKEN_QUERY, &mut inner) }
                .context("`OpenProcessToken` failed")?;
            Ok(Self { inner })
        }

        fn is_elevated(&self) -> Result<bool> {
            let mut elevation = TOKEN_ELEVATION::default();
            let token_elevation_sz = u32::try_from(size_of::<TOKEN_ELEVATION>())
                .expect("`TOKEN_ELEVATION` size should fit into a u32");
            let mut return_size = 0u32;
            // SAFETY: Docs say nothing about threads or safety <https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-gettokeninformation>
            // The type of `elevation` varies based on the 2nd parameter, but we hard-coded that.
            // It should be fine.
            unsafe {
                GetTokenInformation(
                    self.inner,
                    TokenElevation,
                    Some(&mut elevation as *mut _ as *mut c_void),
                    token_elevation_sz,
                    &mut return_size as *mut _,
                )
            }?;
            Ok(elevation.TokenIsElevated == 1)
        }
    }

    impl Drop for ProcessToken {
        fn drop(&mut self) {
            // SAFETY: We got `inner` from `OpenProcessToken` and didn't mutate it after that.
            // Closing a pseudo-handle is a harmless no-op, though this is a real handle.
            // <https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getcurrentprocess>
            // > The pseudo handle need not be closed when it is no longer needed. Calling the CloseHandle function with a pseudo handle has no effect. If the pseudo handle is duplicated by DuplicateHandle, the duplicate handle must be closed.
            unsafe { CloseHandle(self.inner) }.expect("`CloseHandle` should always succeed");
            self.inner = HANDLE::default();
        }
    }
}

#[cfg(test)]
mod tests {
    // Make sure it doesn't crash
    #[test]
    fn is_normal_user() {
        super::is_normal_user().unwrap();
    }
}
