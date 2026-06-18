fn main() {
    // Define a convenience `apple` cfg for all Darwin targets (macOS, iOS, ...), so the source
    // can use `#[cfg(apple)]` instead of repeating `target_vendor = "apple"` everywhere.
    //
    // Note: `Cargo.toml`'s `[target.'cfg(...)']` cannot use this - Cargo evaluates those before
    // build scripts run - so dependency gating there stays on `target_vendor = "apple"`.
    println!("cargo::rustc-check-cfg=cfg(apple)");

    if std::env::var("CARGO_CFG_TARGET_VENDOR").as_deref() == Ok("apple") {
        println!("cargo::rustc-cfg=apple");
    }
}
