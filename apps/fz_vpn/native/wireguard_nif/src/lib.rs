//! wireguard bridge from elixir to rust to set and show configurations on an
//! interface

use wireguard_control::{Backend, InterfaceName, Device};

#[cfg(target_os = "linux")]
const BACKEND: Backend = Backend::Kernel;
#[cfg(not(target_os = "linux"))]
const BACKEND: Backend = Backend::Userspace;

#[rustler::nif]
fn set(config_str: &str, name: &str) {
    let iface_name: InterfaceName = name.parse().unwrap();
    let device = Device::get(&iface_name, BACKEND).unwrap();

    println!("config for {}: {}", iface_name, config_str);
}

#[rustler::nif]
fn show(subcommand: &str, name: &str) {}

rustler::init!("Elixir.FzVpn.CLI.Wireguard", [set, show]);
