//! A module for registering deep links that are sent over to the app's already-running instance
//! Based on reading some of the Windows code from https://github.com/FabianLars/tauri-plugin-deep-link, which is licensed "MIT OR Apache-2.0"

use std::{io, path::Path};

pub(crate) const FZ_SCHEME: &str = "firezone-fd0020211111";

#[derive(thiserror::Error, Debug)]
pub enum DeepLinkError {
    /// Something went wrong finding the path to our own exe
    #[error(transparent)]
    CurrentExe(io::Error),
    /// Something went wrong setting up the registry
    #[error(transparent)]
    WindowsRegistry(io::Error),
}

// Registers the current exe as the handler for our deep link scheme.
//
// This is copied almost verbatim from tauri-plugin-deep-link's `register` fn, with an improvement
// that we send the deep link to a subcommand so the URL won't confuse `clap`
//
// * `id` A unique ID for the app, e.g. "com.contoso.todo-list" or "dev.firezone.client"
pub fn register(id: &str) -> Result<(), DeepLinkError> {
    let exe = tauri_utils::platform::current_exe()
        .map_err(DeepLinkError::CurrentExe)?
        .display()
        .to_string()
        .replace("\\\\?\\", "");

    set_registry_values(id, &exe).map_err(DeepLinkError::WindowsRegistry)?;

    Ok(())
}

/// Set up the Windows registry to call the given exe when our deep link scheme is used
///
/// All errors from this function are registry-related
fn set_registry_values(id: &str, exe: &str) -> Result<(), io::Error> {
    let hkcu = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER);
    let base = Path::new("Software").join("Classes").join(FZ_SCHEME);

    let (key, _) = hkcu.create_subkey(&base)?;
    key.set_value("", &format!("URL:{}", id))?;
    key.set_value("URL Protocol", &"")?;

    let (icon, _) = hkcu.create_subkey(base.join("DefaultIcon"))?;
    icon.set_value("", &format!("{},0", &exe))?;

    let (cmd, _) = hkcu.create_subkey(base.join("shell").join("open").join("command"))?;
    cmd.set_value("", &format!("{} open-deep-link \"%1\"", &exe))?;

    Ok(())
}
