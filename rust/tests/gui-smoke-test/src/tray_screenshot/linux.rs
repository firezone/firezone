use anyhow::{Context as _, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    ffi::OsString,
    fs::{self, File},
    os::unix::fs::DirBuilderExt as _,
    path::Path,
    time::{Duration, Instant},
};
use subprocess::{Exec, Job, Redirection};
use zbus::blocking::{Connection, connection::Builder};

const YARU_RESOURCE: &str = "/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource";
const DIAGNOSTICS: &str = "target/gui-smoke-test/gnome-tray";

/// Photographs the native GNOME AppIndicator menu on a bus supplied by `dbus-run-session`.
pub(crate) fn capture(submenu: &str, output: &Path) -> Result<()> {
    let output = std::path::absolute(output)?;
    fs::create_dir_all(
        output
            .parent()
            .context("Screenshot has no parent directory")?,
    )?;
    // A failed capture must not upload the reference image from the checkout.
    if output.exists() {
        fs::remove_file(&output)?;
    }

    let mut session = Session::new()?;
    let result = session.photograph(submenu, &output);
    if result.is_err() {
        if let Err(error) = session.save_menu() {
            tracing::warn!("Failed to collect menu diagnostics: {error:#}");
        }
        let desktop = std::path::absolute(Path::new(DIAGNOSTICS).join("failure-desktop.png"))?;
        if let Err(error) = session.screenshot([0, 0, 1920, 1080], &desktop) {
            tracing::warn!("Failed to capture the desktop: {error:#}");
        }
    }
    drop(session);
    result?;

    Ok(())
}

struct Session {
    directory: tempfile::TempDir,
    environment: HashMap<String, String>,
    connection: Connection,
    processes: Vec<Process>,
    deadline: Instant,
}

impl Session {
    fn new() -> Result<Self> {
        let connection = Builder::session()?
            .method_timeout(Duration::from_secs(10))
            .build()?;
        ensure!(
            !name_has_owner(&connection, "org.gnome.Shell")?,
            "Run the screenshot in an isolated bus with `dbus-run-session`"
        );

        let directory = tempfile::Builder::new().prefix("gnome-tray-").tempdir()?;
        let mut environment = [
            ("XDG_CURRENT_DESKTOP", "GNOME"),
            ("XDG_SESSION_TYPE", "wayland"),
            ("GNOME_SHELL_SESSION_MODE", "user"),
            ("WAYLAND_DISPLAY", "wayland-0"),
            ("GDK_BACKEND", "wayland"),
            ("LIBGL_ALWAYS_SOFTWARE", "1"),
            ("GALLIUM_DRIVER", "llvmpipe"),
            ("LP_NUM_THREADS", "1"),
            ("GTK_THEME", "Yaru"),
            ("LANG", "en_US.UTF-8"),
            ("LC_ALL", "en_US.UTF-8"),
            ("FIREZONE_NO_TELEMETRY", "true"),
        ]
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value.to_owned()))
        .collect::<HashMap<_, _>>();
        for (key, name) in [
            ("XDG_RUNTIME_DIR", "runtime"),
            ("XDG_CONFIG_HOME", "config"),
            ("XDG_DATA_HOME", "data"),
            ("XDG_CACHE_HOME", "cache"),
        ] {
            let path = directory.path().join(name);
            fs::DirBuilder::new().mode(0o700).create(&path)?;
            environment.insert(
                key.to_owned(),
                path.to_str().context("Invalid session path")?.to_owned(),
            );
        }
        connection.call_method(
            Some("org.freedesktop.DBus"),
            "/org/freedesktop/DBus",
            Some("org.freedesktop.DBus"),
            "UpdateActivationEnvironment",
            &(&environment,),
        )?;
        fs::create_dir_all(DIAGNOSTICS)?;

        Ok(Self {
            directory,
            environment,
            connection,
            processes: Vec::new(),
            deadline: Instant::now() + Duration::from_secs(240),
        })
    }

    fn photograph(&mut self, submenu: &str, output: &Path) -> Result<()> {
        self.prepare()?;
        self.spawn(
            "gnome-shell",
            self.command("gnome-shell").args([
                "--wayland",
                "--headless",
                "--virtual-monitor",
                "1920x1080",
                "--unsafe-mode",
            ]),
        )?;
        self.wait_for("GNOME Shell", || {
            Ok(self.eval("!Main.layoutManager._startingUp")?.as_bool() == Some(true))
        })?;
        self.wait_for("StatusNotifierWatcher", || {
            let ready = name_has_owner(&self.connection, "org.kde.StatusNotifierWatcher")?;
            Ok(ready)
        })?;
        self.eval(include_str!("gnome.js"))?;
        let stylesheet = self.directory.path().join("yaru.css");
        let arguments = json!([YARU_RESOURCE, stylesheet]);
        self.eval(&format!(
            "global.firezoneScreenshot.prepare(...{arguments})"
        ))?;
        run(self
            .command("gnome-keyring-daemon")
            .args(["--unlock", "--components=secrets"])
            .stdin(Redirection::Null))?;
        self.wait_for("Wayland display", || {
            Ok(self.directory.path().join("runtime/wayland-0").exists())
        })?;
        let gui = crate::gui_path()
            .canonicalize()
            .context("Failed to locate the built GUI client")?;
        self.spawn(
            "client",
            self.command(gui).args([
                "--mock-tunnel",
                "--skip-portal-auth",
                "--no-error-dialog",
                "--no-deep-links",
                "--no-elevation-check",
            ]),
        )?;
        let open = format!("global.firezoneScreenshot.open({})", json!(submenu));
        self.wait_for("resource submenu", || {
            Ok(self.eval(&open)?.as_bool() == Some(true))
        })?;
        self.wait_for("menu geometry", || {
            Ok(!self.eval("global.firezoneScreenshot.bounds()")?.is_null())
        })?;
        std::thread::sleep(Duration::from_secs(2));
        let bounds =
            serde_json::from_value::<[i32; 4]>(self.eval("global.firezoneScreenshot.bounds()")?)?;
        self.save_menu()?;
        fs::write(
            Path::new(DIAGNOSTICS).join("geometry.json"),
            serde_json::to_vec(&bounds)?,
        )?;
        self.screenshot(bounds, output)?;
        tracing::info!(path = %output.display(), "Saved tray screenshot");

        Ok(())
    }

    fn prepare(&self) -> Result<()> {
        for (schema, key, value) in [
            ("org.gnome.desktop.interface", "enable-animations", "false"),
            (
                "org.gnome.desktop.interface",
                "color-scheme",
                "prefer-light",
            ),
            ("org.gnome.desktop.interface", "font-name", "Cantarell 11"),
            ("org.gnome.desktop.interface", "text-scaling-factor", "1.0"),
            ("org.gnome.desktop.interface", "scaling-factor", "1"),
            ("org.gnome.desktop.session", "idle-delay", "0"),
            ("org.gnome.desktop.screensaver", "lock-enabled", "false"),
            ("org.gnome.desktop.background", "picture-uri", "''"),
            ("org.gnome.desktop.background", "picture-uri-dark", "''"),
            ("org.gnome.desktop.background", "primary-color", "#ffffff"),
            (
                "org.gnome.desktop.background",
                "color-shading-type",
                "solid",
            ),
            (
                "org.gnome.shell",
                "welcome-dialog-last-shown-version",
                "999",
            ),
            ("org.gnome.shell", "disable-user-extensions", "false"),
            (
                "org.gnome.shell",
                "enabled-extensions",
                "['ubuntu-appindicators@ubuntu.com']",
            ),
        ] {
            run(self.command("gsettings").args(["set", schema, key, value]))?;
        }
        run(self
            .command("dpkg-query")
            .args([
                "-W",
                "gnome-shell",
                "gnome-shell-extension-appindicator",
                "yaru-theme-gnome-shell",
                "fonts-cantarell",
                "libgl1-mesa-dri",
            ])
            .stdout(File::create(Path::new(DIAGNOSTICS).join("packages.txt"))?))?;
        run(self
            .command("gresource")
            .args([
                "extract",
                YARU_RESOURCE,
                "/org/gnome/shell/theme/Yaru/gnome-shell.css",
            ])
            .stdout(File::create(self.directory.path().join("yaru.css"))?))?;

        Ok(())
    }

    fn command(&self, program: impl Into<OsString>) -> Exec {
        Exec::cmd(program)
            .env_extend(self.environment.clone())
            .env_remove("DISPLAY")
    }

    fn spawn(&mut self, name: &str, command: Exec) -> Result<()> {
        let log = File::create(Path::new(DIAGNOSTICS).join(format!("{name}.log")))?;
        let job = command.stdout(log).stderr(Redirection::Merge).start()?;
        self.processes.push(Process(job));

        Ok(())
    }

    fn wait_for(&self, description: &str, predicate: impl Fn() -> Result<bool>) -> Result<()> {
        let mut last_error = None;
        while Instant::now() < self.deadline {
            for Process(job) in &self.processes {
                ensure!(
                    job.poll().is_none(),
                    "Process exited while waiting for {description}"
                );
            }
            match predicate() {
                Ok(true) => {
                    tracing::info!(description, "Ready");
                    return Ok(());
                }
                Ok(false) => {}
                Err(error) => last_error = Some(error),
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        bail!("Timed out waiting for {description}: {last_error:?}");
    }

    fn eval(&self, code: &str) -> Result<Value> {
        let reply = self.connection.call_method(
            Some("org.gnome.Shell"),
            "/org/gnome/Shell",
            Some("org.gnome.Shell"),
            "Eval",
            &(code,),
        )?;
        let (success, value) = reply.body().deserialize::<(bool, String)>()?;
        ensure!(success, "GNOME Shell evaluation failed: {value}");
        let value = serde_json::from_str(&value).context("Invalid GNOME Shell response")?;

        Ok(value)
    }

    fn screenshot(&self, bounds: [i32; 4], output: &Path) -> Result<()> {
        let [x, y, width, height] = bounds;
        ensure!(
            x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1920 && y + height <= 1080,
            "Invalid menu bounds: {bounds:?}"
        );
        let reply = self.connection.call_method(
            Some("org.gnome.Shell.Screenshot"),
            "/org/gnome/Shell/Screenshot",
            Some("org.gnome.Shell.Screenshot"),
            "ScreenshotArea",
            &(
                x,
                y,
                width,
                height,
                false,
                output.to_str().context("Invalid screenshot path")?,
            ),
        )?;
        let (success, filename) = reply.body().deserialize::<(bool, String)>()?;
        ensure!(
            success && output.is_file(),
            "GNOME screenshot failed: {filename}"
        );

        Ok(())
    }

    fn save_menu(&self) -> Result<()> {
        let menu = self.eval("global.firezoneScreenshot.describe()")?;
        fs::write(
            Path::new(DIAGNOSTICS).join("menu.json"),
            serde_json::to_vec_pretty(&menu)?,
        )?;

        Ok(())
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        while let Some(process) = self.processes.pop() {
            drop(process);
        }
        // The document portal outlives the shell until dbus-run-session exits.
        let mount = self.directory.path().join("runtime/doc");
        if mount.exists()
            && let Err(error) = run(self.command("fusermount3").arg("-u").arg(mount))
        {
            tracing::warn!("Failed to unmount the document portal: {error:#}");
        }
        for name in ["gnome-shell.log", "client.log"] {
            if let Ok(log) = fs::read_to_string(Path::new(DIAGNOSTICS).join(name)) {
                tracing::info!(name, "{log}");
            }
        }
    }
}

fn name_has_owner(connection: &Connection, name: &str) -> Result<bool> {
    let reply = connection.call_method(
        Some("org.freedesktop.DBus"),
        "/org/freedesktop/DBus",
        Some("org.freedesktop.DBus"),
        "NameHasOwner",
        &(name,),
    )?;
    let has_owner = reply.body().deserialize::<bool>()?;

    Ok(has_owner)
}

fn run(command: Exec) -> Result<()> {
    let description = command.to_cmdline_lossy();
    let process = Process(command.start()?);
    let status = process
        .0
        .wait_timeout(Duration::from_secs(10))?
        .with_context(|| format!("Command timed out: {description}"))?;
    ensure!(
        status.success(),
        "Command failed: {description}: {status:?}"
    );

    Ok(())
}

struct Process(Job);

impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.terminate();
        if !matches!(self.0.wait_timeout(Duration::from_secs(2)), Ok(Some(_))) {
            let _ = self.0.kill();
        }
        let _ = self.0.wait();
    }
}
