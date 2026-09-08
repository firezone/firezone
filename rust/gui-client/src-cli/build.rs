fn main() {
    // Only an actual `--profile release` build embeds the SXS manifest that
    // claims the sparse-MSIX package identity. With the claim present but the
    // package not registered, the kernel fails `CreateProcess` with
    // `APPMODEL_ERROR_NO_PACKAGE` (15700), which is the normal state of a
    // binary run straight out of `target\<profile>`. Mirrors the same gate in
    // `src-tauri/build.rs`.
    println!("cargo:rerun-if-env-changed=PROFILE");

    #[cfg(target_os = "windows")]
    if std::env::var("PROFILE").as_deref() == Ok("release") {
        embed_resource::compile_for(
            "win_files/firezone-cli.exe.manifest.rc",
            ["firezone-cli"],
            embed_resource::NONE,
        )
        .manifest_required()
        .expect("Failed to embed the package identity manifest");

        println!("cargo:rerun-if-changed=win_files/firezone-cli.exe.manifest");
        println!("cargo:rerun-if-changed=win_files/firezone-cli.exe.manifest.rc");
    }
}
