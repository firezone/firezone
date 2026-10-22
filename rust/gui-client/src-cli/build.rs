use clap::CommandFactory;
use clap_complete::Shell;
use std::path::{Path, PathBuf};

// The completions are generated from the `Command` rather than by running the
// built binary, so a cross-compiled build produces them too.
#[allow(dead_code, reason = "only the `clap` `Command` is wanted here")]
mod cli {
    include!("src/cli.rs");
}

fn main() {
    generate_completions();

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

fn generate_completions() {
    println!("cargo:rerun-if-changed=src/cli.rs");

    let out_dir = completions_dir();
    std::fs::create_dir_all(&out_dir).expect("Failed to create the completions directory");

    // The crate is named after the binary Cargo builds, but the completions
    // have to name the binary as installed, which is what `BIN_NAME` is.
    // Qualified because `Cli` has an inherent `command` of its own.
    let mut cmd = <cli::Cli as CommandFactory>::command().name(cli::BIN_NAME);

    for shell in [Shell::Bash, Shell::Zsh, Shell::Fish] {
        clap_complete::generate_to(shell, &mut cmd, cli::BIN_NAME, out_dir.clone())
            .expect("Failed to write the completion script");
    }
}

/// `<target>/<profile>/completions`, next to the binary itself.
///
/// `tauri.conf.json` has to name these files, and `OUT_DIR` carries a build hash.
fn completions_dir() -> PathBuf {
    let out_dir = std::env::var_os("OUT_DIR").expect("Cargo always sets `OUT_DIR`");

    Path::new(&out_dir)
        .ancestors()
        .nth(3)
        .expect("`OUT_DIR` is `<target>/<profile>/build/<crate>-<hash>/out`")
        .join("completions")
}
