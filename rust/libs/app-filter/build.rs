use anyhow::Context as _;

fn main() -> anyhow::Result<()> {
    println!("cargo::rerun-if-env-changed=CARGO_FEATURE_EBPF");

    if std::env::var_os("CARGO_FEATURE_EBPF").is_none() {
        return Ok(());
    }

    build_ebpf()?;

    // `AYA_BUILD_SKIP=1` (or a non-Linux host) lets the crate type-check without the eBPF toolchain; the program then fails to load.
    let out_dir = std::env::var("OUT_DIR").context("`OUT_DIR` not set")?;
    let program = std::path::Path::new(&out_dir).join("app-filter-ebpf-main");
    if !program.exists() {
        std::fs::write(&program, []).context("Failed to write placeholder eBPF program")?;
    }

    Ok(())
}

#[cfg(target_os = "linux")]
fn build_ebpf() -> anyhow::Result<()> {
    let manifest_dir =
        std::env::var("CARGO_MANIFEST_DIR").context("`CARGO_MANIFEST_DIR` not set")?;
    let libs_dir = std::path::Path::new(&manifest_dir)
        .parent()
        .context("`CARGO_MANIFEST_DIR` has no parent directory")?;
    let root_dir = libs_dir.join("app-filter-ebpf");
    let root_dir = root_dir.to_str().context("path is not valid UTF-8")?;

    // `aya_build` only watches the eBPF crate itself, but its code also comes from the shared crate.
    println!(
        "cargo::rerun-if-changed={}",
        libs_dir.join("app-filter-ebpf-shared").display()
    );

    aya_build::build_ebpf(
        [aya_build::Package {
            name: "app-filter-ebpf",
            root_dir,
            ..Default::default()
        }],
        aya_build::Toolchain::Custom("nightly-2026-10-17"),
    )?;

    Ok(())
}

#[cfg(not(target_os = "linux"))]
#[expect(
    clippy::unnecessary_wraps,
    reason = "Signature must match the Linux build"
)]
fn build_ebpf() -> anyhow::Result<()> {
    Ok(())
}
