fn main() {
    // `FIREZONE_NO_TELEMETRY` is also a run-time flag, but CI stamps the
    // build-time value in as well so every artifact that is not a release
    // stays silent even where nothing sets the variable at run time.
    println!("cargo:rerun-if-env-changed=FIREZONE_NO_TELEMETRY");
    println!("cargo:rustc-check-cfg=cfg(no_telemetry)");
    if std::env::var("FIREZONE_NO_TELEMETRY").as_deref() == Ok("true") {
        println!("cargo:rustc-cfg=no_telemetry");
    }
}
