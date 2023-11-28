use embed_manifest::{embed_manifest, new_manifest};

fn main() {
    if std::env::var_os("CARGO_CFG_WINDOWS").is_some() {
        embed_manifest(new_manifest("Contoso.Sample")).expect("unable to embed manifest file");
    }
    println!("cargo:rerun-if-changed=build.rs");

    if cfg!(target_os = "windows") {
        let mut res = winres::WindowsResource::new();
        res.set_icon("favicon.ico")
            .set("CompanyName", "Firezone, Inc.")
            .set("InternalName", "Firezone Windows Client")
            .set("ProductName", "Firezone Windows Client");
        res.compile().unwrap();
    }
}
