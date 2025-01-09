const XCODE_CONFIGURATION_ENV: &str = "CONFIGURATION";

fn main() {
    let out_dir = "../../../../swift/apple/FirezoneNetworkExtension/Connlib/Generated";

    let bridges = vec!["src/lib.rs"];
    for path in &bridges {
        println!("cargo:rerun-if-changed={}", path);
    }
    println!("cargo:rerun-if-env-changed={}", XCODE_CONFIGURATION_ENV);

    swift_bridge_build::parse_bridges(bridges)
        .write_all_concatenated(out_dir, env!("CARGO_PKG_NAME"));
}
