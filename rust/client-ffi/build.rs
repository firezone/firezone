use std::{env, path::Path, process::Command};

fn main() {
    if env::var("TARGET").as_deref() != Ok("i686-linux-android") {
        return;
    }

    println!("cargo:rerun-if-env-changed=CARGO_TARGET_I686_LINUX_ANDROID_LINKER");
    let linker = env::var("CARGO_TARGET_I686_LINUX_ANDROID_LINKER")
        .expect("i686 Android builds need an NDK linker");
    let output = Command::new(linker)
        .arg("--print-file-name=libclang_rt.builtins-i686-android.a")
        .output()
        .expect("failed to locate the NDK compiler runtime");
    assert!(
        output.status.success(),
        "NDK compiler runtime lookup failed"
    );
    let archive = String::from_utf8(output.stdout).expect("NDK linker returned invalid UTF-8");
    let archive = Path::new(archive.trim());
    assert!(archive.is_file(), "NDK compiler runtime archive is missing");

    let runtime_dir = archive
        .parent()
        .expect("NDK compiler runtime archive has no parent directory");

    // Rust's -nodefaultlibs omits the runtime needed by mimalloc's 64-bit atomics.
    println!("cargo:rustc-link-search=native={}", runtime_dir.display());
    println!("cargo:rustc-link-lib=static=clang_rt.builtins-i686-android");
}
