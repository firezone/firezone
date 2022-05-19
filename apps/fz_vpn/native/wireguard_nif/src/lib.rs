//! wireguard bridge from elixir to rust to set and show configurations on an
//! interface

#[rustler::nif]
fn set(_config_str: &str, _name: &str) {}

#[rustler::nif]
fn show(_subcommand: &str, _name: &str) {}

rustler::init!("Elixir.FzVpn.Wireguard", [set, show]);
