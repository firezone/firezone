//! NIF implementations to interact with wireguard

use std::collections::HashMap;

use rustler::Term;

#[rustler::nif]
fn set(_config: HashMap<Term, &str>, _name: &str) {}

#[rustler::nif]
fn show(_subcommand: &str, _name: &str) {}

rustler::init!("Elixir.FzVpn.WireguardBridge", [set, show]);
