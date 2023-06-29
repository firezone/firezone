// Referenced from https://github.com/chinedufn/swift-bridge/blob/master/examples/rust-binary-calls-swift-package/build.rs

use std::path::PathBuf;
use walkdir::WalkDir;

static XCODE_CONFIGURATION_ENV: &str = "CONFIGURATION";
static SWIFT_PKG_NAME: &str = "Connlib";
static SWIFT_LIB_NAME: &str = "libConnlib.a";
static BRIDGE_SRCS: &[&str] = &["src/lib.rs"];
static BRIDGING_HEADER: &str = "BridgingHeader-SwiftPM.h";
static MACOSX_DEPLOYMENT_TARGET: &str = "12.4";
static IPHONEOS_DEPLOYMENT_TARGET: &str = "15.6";

mod sdk {
    pub static MACOS: &str = "macosx";
    pub static IOS: &str = "iphoneos";
    pub static IOS_SIM: &str = "iphonesimulator";
}

struct Env {
    swift_pkg_dir: PathBuf,
    swift_src_dir: PathBuf,
    bridge_dst_dir: PathBuf,
    swift_built_lib_dir: PathBuf,
    release: bool,
    triple: String,
    sdk: &'static str,
}

impl Env {
    fn gather() -> Self {
        let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
        let swift_pkg_dir = manifest_dir;
        let swift_src_dir = swift_pkg_dir.join("Sources").join(SWIFT_PKG_NAME);
        let bridge_dst_dir = swift_src_dir.join("Generated");
        let release = std::env::var("PROFILE").unwrap() == "release";
        let target = std::env::var("TARGET").unwrap();
        let (triple, sdk) = match target.as_str() {
            "aarch64-apple-darwin" => (
                format!("arm64-apple-macosx{MACOSX_DEPLOYMENT_TARGET}"),
                sdk::MACOS,
            ),
            "x86_64-apple-darwin" => (
                format!("x86_64-apple-macosx{MACOSX_DEPLOYMENT_TARGET}"),
                sdk::MACOS,
            ),
            "aarch64-apple-ios" => (
                format!("arm64-apple-ios{IPHONEOS_DEPLOYMENT_TARGET}"),
                sdk::IOS,
            ),
            "aarch64-apple-ios-sim" => (
                format!("arm64-apple-ios{IPHONEOS_DEPLOYMENT_TARGET}-simulator"),
                sdk::IOS_SIM,
            ),
            "x86_64-apple-ios" | "x86_64-apple-ios-sim" => (
                format!("x86_64-apple-ios{IPHONEOS_DEPLOYMENT_TARGET}-simulator"),
                sdk::IOS_SIM,
            ),
            _ => todo!("unsupported target triple: {target:?}"),
        };
        let swift_built_lib_dir = swift_pkg_dir.join(".build").join(&triple).join(if release {
            "release"
        } else {
            "debug"
        });
        Self {
            swift_pkg_dir,
            swift_src_dir,
            bridge_dst_dir,
            swift_built_lib_dir,
            release,
            triple,
            sdk,
        }
    }
}

fn gen_bridges(env: &Env) {
    for path in BRIDGE_SRCS {
        println!("cargo:rerun-if-changed={path}");
    }
    swift_bridge_build::parse_bridges(BRIDGE_SRCS)
        .write_all_concatenated(&env.bridge_dst_dir, env!("CARGO_PKG_NAME"));
}

// We use `swiftc` instead of SwiftPM/`swift build` because of this limitation:
// https://github.com/apple/swift-package-manager/pull/6572
fn compile_swift(env: &Env) -> anyhow::Result<()> {
    let swift_sdk = diva::Command::parse("xcrun --show-sdk-path --sdk")
        .with_arg(env.sdk)
        .run_and_wait_for_trimmed()?;
    let swift_src_files = WalkDir::new(&env.swift_src_dir)
        .into_iter()
        .filter_map(Result::ok)
        .filter_map(|entry| {
            (entry.path().extension() == Some("swift".as_ref())).then(|| entry.path().to_owned())
        });
    std::fs::create_dir_all(&env.swift_built_lib_dir)?;
    diva::Command::parse("swiftc -emit-library -static")
        .with_args(["-module-name", SWIFT_PKG_NAME])
        .with_arg("-import-objc-header")
        .with_arg(env.swift_src_dir.join(BRIDGING_HEADER))
        .with_arg("-sdk")
        .with_arg(swift_sdk)
        .with_args(["-target", &env.triple])
        // https://github.com/apple/swift-package-manager/blob/55006dce81ae70cd8f2b78479038423eeebde1e4/Documentation/Usage.md#setting-the-build-configuration
        .with_parsed_args(if !env.release {
            "-Onone -g -enable-testing"
        } else {
            "-O -whole-module-optimization"
        })
        .with_arg("-o")
        .with_arg(env.swift_built_lib_dir.join(SWIFT_LIB_NAME))
        .with_args(swift_src_files)
        .with_cwd(&env.swift_pkg_dir)
        .run_and_wait()?;
    Ok(())
}

fn link_swift(env: &Env) {
    println!("cargo:rustc-link-lib=static={SWIFT_PKG_NAME}");
    println!(
        "cargo:rustc-link-search={}",
        env.swift_built_lib_dir.display()
    );
    let xcode_path = diva::Command::parse("xcode-select --print-path")
        .run_and_wait_for_trimmed()
        .unwrap_or_else(|_| "/Applications/Xcode.app/Contents/Developer".to_owned());
    println!("cargo:rustc-link-search={xcode_path}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx/");
    println!("cargo:rustc-link-search=/usr/lib/swift");
}

fn main() -> anyhow::Result<()> {
    // Early exit build script to avoid errors on non-Apple platforms.
    if !cfg!(target_vendor = "apple") {
        return Ok(());
    }

    println!("cargo:rerun-if-env-changed={XCODE_CONFIGURATION_ENV}");
    let env = Env::gather();
    gen_bridges(&env);
    compile_swift(&env)?;
    link_swift(&env);
    Ok(())
}
