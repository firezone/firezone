fn main() {
    // `system_certs` is set through `RUSTFLAGS` by the Nix builds, not by Cargo, so declare it
    // here to keep `unexpected_cfgs` quiet. Setting it is what switches the portal connection to
    // the platform's root certificates.
    println!("cargo::rustc-check-cfg=cfg(system_certs)");
}
