//! Identity of the Firezone sparse MSIX package.
//!
//! Derived at build time from the manifest's `Name` + Publisher DN so
//! that the GUI, the IPC layer and the WiX installer all agree on it.

/// `Name_publisherId` for the sparse MSIX.
///
/// Used by `register-sparse.exe` to stage / provision / deprovision the
/// package against the AppX deployment service, to derive the package
/// AUMID (`<PACKAGE_FAMILY_NAME>!Firezone`) that Windows uses to label
/// toast notifications, and to key the conditional ACEs on the IPC pipes.
pub const PACKAGE_FAMILY_NAME: &str = env!("FIREZONE_PACKAGE_FAMILY_NAME");
