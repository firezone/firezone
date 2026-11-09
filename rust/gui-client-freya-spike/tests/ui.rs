//! Renders every screen of `screenshots.test.tsx` and drives the interactions of the `*.test.tsx` files.

use std::{collections::HashMap, error::Error, path::PathBuf, time::Duration};

use freya::prelude::*;
use freya_testing::prelude::*;
use gui_client_freya_spike::*;
use tokio::sync::mpsc;

/// The window the client opens, from `tauri.conf.json`.
const SIZE: (f32, f32) = (900., 500.);

struct Ui {
    t: TestingRunner,
    vm: State<ViewModel>,
    requests: mpsc::UnboundedReceiver<Request>,
}

fn launch(page: Page, dark: bool, model: ViewModel) -> Ui {
    let (tx, requests) = mpsc::unbounded_channel();
    let (mut t, vm) = TestingRunner::new(
        app,
        SIZE.into(),
        |r| {
            let vm = State::create_global(model);
            r.provide_root_context(|| Bridge {
                vm,
                requests: tx,
                dark,
                start_page: page,
            });
            vm
        },
        1.,
    );
    for (family, bytes) in FONTS {
        // One file per call: `set_fonts` takes a map keyed by family name.
        t.set_fonts(HashMap::from([(family, bytes)]));
    }
    t.set_default_fonts(&[SANS.into()]);
    t.run_in(|| {
        GlobalContexts::get().insert_context(Clipboard::create(Some(Box::new(
            MemoryClipboard::default(),
        ))))
    });
    t.sync_and_update();
    settle(&mut t);
    Ui { t, vm, requests }
}

fn settle(t: &mut TestingRunner) {
    t.poll(Duration::from_millis(5), Duration::from_millis(60));
}

fn screenshot(t: &mut TestingRunner, name: &str) {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("screenshots");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(format!("{name}.png")), t.render().as_bytes()).unwrap();
}

fn texts(t: &TestingRunner) -> Vec<String> {
    t.find_many(|_, el| {
        Label::try_downcast(el)
            .map(|l| l.text.to_string())
            .or_else(|| {
                Paragraph::try_downcast(el)
                    .map(|p| p.spans.iter().map(|s| s.text.as_ref()).collect())
            })
    })
}

/// The centre of the label showing `text`, like `getByText`.
fn text_at(t: &TestingRunner, text: &str) -> (f64, f64) {
    t.find(|n, el| {
        Label::try_downcast(el)
            .filter(|l| l.text == text)
            .map(|_| n.layout().area.center())
    })
    .map(|c| (c.x as f64, c.y as f64))
    .unwrap_or_else(|| panic!("no {text:?} in {:?}", texts(t)))
}

/// The centre of the element named `name`, like `getByRole(_, { name })`.
fn named_at(t: &TestingRunner, name: &str) -> (f64, f64) {
    t.find(|n, el| {
        Rect::try_downcast(el)
            .filter(|r| r.accessibility.builder.label() == Some(name))
            .map(|_| n.layout().area.center())
    })
    .map(|c| (c.x as f64, c.y as f64))
    .unwrap_or_else(|| panic!("nothing named {name:?}"))
}

fn click(t: &mut TestingRunner, at: (f64, f64)) {
    t.move_cursor(at);
    t.click_cursor(at);
    settle(t);
}

/// Replaces what the field next to `label` holds, then presses Enter, like `userEvent.fill`.
fn fill(t: &mut TestingRunner, label: &str, value: &str) {
    let y = text_at(t, label).1;
    click(t, (750., y));
    t.send_event(PlatformEvent::Keyboard {
        name: KeyboardEventName::KeyDown,
        key: Key::Character("a".into()),
        code: Code::Unidentified,
        modifiers: Modifiers::CONTROL,
    });
    t.write_text(value);
    t.press_key(Key::Named(NamedKey::Enter));
    settle(t);
}

fn general_settings() -> GeneralSettings {
    GeneralSettings {
        start_minimized: true,
        start_on_login: true,
        account_slug: "example-corp".into(),
        control_plane: ControlPlane::CloudUs,
        auth_url: "https://app.firezone.dev/".into(),
        api_url: "wss://api.firezone.dev/".into(),
        custom_auth_url: "https://app.firezone.dev/".into(),
        custom_api_url: "wss://api.firezone.dev/".into(),
        ..Default::default()
    }
}

fn custom_settings() -> GeneralSettings {
    GeneralSettings {
        control_plane: ControlPlane::Custom,
        auth_url: "https://firezone.example.com/".into(),
        api_url: "wss://api.firezone.example.com/".into(),
        ..general_settings()
    }
}

fn log_filter() -> Option<LogFilter> {
    Some(LogFilter {
        log_filter: "info".into(),
        log_filter_is_managed: false,
    })
}

fn certificate() -> Vec<CertField> {
    const CN: &str = "dev.firezone.device-trust";
    [
        ("Common Name", CN.to_owned()),
        ("Subject", format!("O=Example Corp, CN={CN}")),
        ("Issuer", "DC=com, DC=example, CN=Example Corp Issuing CA 1".into()),
        ("MDM Device ID", "9a1c7d4e-5f60-4b28-8c3a-2d5e7f9b0c14".into()),
        ("Device Serial", "PF2X9K7L".into()),
        ("Serial Number", "3a:68:e8:18:bf:83:6b:20:c4:37:16:ec:96:d2:7a:a4".into()),
        ("Not Before", "Mar 12 09:12:44 2026 +00:00".into()),
        ("Not After", "Jun 14 09:12:44 2028 +00:00".into()),
        ("Signing Algorithm", "SHA256withRSA".into()),
        (
            "SHA-256 Fingerprint",
            "90:E4:45:C9:E2:8E:8F:5B:57:D2:30:90:8C:6F:B2:3D:CE:A1:61:CA:96:3E:BF:B2:8E:E7:3D:A9:CF:70:DD:B7".into(),
        ),
    ]
    .into_iter()
    .map(|(label, value)| CertField { label: label.into(), value: Some(value), problem: None })
    .collect()
}

#[derive(Default)]
struct Screen {
    vm: ViewModel,
    click: Option<&'static str>,
    input: Option<(&'static str, &'static str)>,
}

/// Every screen of `screenshots.test.tsx`, in the same states.
fn screens() -> Vec<(&'static str, Page, Screen)> {
    let vm = ViewModel::default;
    let logs = Some(FileCount {
        bytes: 3_400_000,
        files: 12,
    });
    vec![
        (
            "overview-signed-out",
            Page::Overview,
            Screen {
                vm: ViewModel {
                    session: Some(Session::SignedOut),
                    ..vm()
                },
                ..Default::default()
            },
        ),
        (
            "overview-loading",
            Page::Overview,
            Screen {
                vm: ViewModel {
                    session: Some(Session::Loading),
                    ..vm()
                },
                ..Default::default()
            },
        ),
        (
            "overview-signed-in",
            Page::Overview,
            Screen {
                vm: ViewModel {
                    session: Some(Session::SignedIn {
                        account_slug: "example-corp".into(),
                        actor_name: "Jane Doe".into(),
                    }),
                    ..vm()
                },
                ..Default::default()
            },
        ),
        (
            "general-settings",
            Page::Settings,
            Screen {
                vm: ViewModel {
                    general_settings: Some(general_settings()),
                    ..vm()
                },
                ..Default::default()
            },
        ),
        (
            "general-settings-custom",
            Page::Settings,
            Screen {
                vm: ViewModel {
                    general_settings: Some(custom_settings()),
                    ..vm()
                },
                ..Default::default()
            },
        ),
        (
            "general-settings-invalid-url",
            Page::Settings,
            Screen {
                vm: ViewModel {
                    general_settings: Some(custom_settings()),
                    ..vm()
                },
                input: Some(("Auth URL", "firezone.example.com")),
                ..Default::default()
            },
        ),
        (
            "general-settings-pending-sign-in",
            Page::Settings,
            Screen {
                vm: ViewModel {
                    general_settings: Some(GeneralSettings {
                        signed_in_with: Some(SignInSettings {
                            account_slug: "example-corp".into(),
                            control_plane: ControlPlane::CloudEu,
                            auth_url: "https://eu.app.firezone.dev/".into(),
                            api_url: "wss://eu.api.firezone.dev/".into(),
                        }),
                        ..general_settings()
                    }),
                    ..vm()
                },
                ..Default::default()
            },
        ),
        (
            "general-settings-managed",
            Page::Settings,
            Screen {
                vm: ViewModel {
                    general_settings: Some(GeneralSettings {
                        account_slug_is_managed: true,
                        start_on_login_is_managed: true,
                        connect_on_start_is_managed: true,
                        control_plane: ControlPlane::CloudEu,
                        auth_url: "https://eu.app.firezone.dev/".into(),
                        auth_url_is_managed: true,
                        api_url: "wss://eu.api.firezone.dev/".into(),
                        api_url_is_managed: true,
                        ..general_settings()
                    }),
                    ..vm()
                },
                ..Default::default()
            },
        ),
        (
            "device-trust-happy",
            Page::DeviceTrust,
            Screen {
                vm: ViewModel {
                    certificate: Some(certificate()),
                    ..vm()
                },
                ..Default::default()
            },
        ),
        ("diagnostics-no-logs", Page::Diagnostics, Screen::default()),
        (
            "diagnostics",
            Page::Diagnostics,
            Screen {
                vm: ViewModel {
                    log_count: logs,
                    log_filter: log_filter(),
                    ..vm()
                },
                ..Default::default()
            },
        ),
        (
            "diagnostics-clear-confirmation",
            Page::Diagnostics,
            Screen {
                vm: ViewModel {
                    log_count: Some(FileCount {
                        bytes: 3_400_000,
                        files: 17,
                    }),
                    log_filter: log_filter(),
                    ..vm()
                },
                click: Some("Clear Logs"),
                ..Default::default()
            },
        ),
        (
            "settings-reset-confirmation",
            Page::Settings,
            Screen {
                vm: ViewModel {
                    general_settings: Some(general_settings()),
                    ..vm()
                },
                click: Some("Reset to Defaults"),
                ..Default::default()
            },
        ),
        (
            "diagnostics-managed",
            Page::Diagnostics,
            Screen {
                vm: ViewModel {
                    log_count: logs,
                    log_filter: Some(LogFilter {
                        log_filter: "debug".into(),
                        log_filter_is_managed: true,
                    }),
                    ..vm()
                },
                ..Default::default()
            },
        ),
        ("about", Page::About, Screen::default()),
    ]
}

#[test]
fn screenshots() {
    for (name, page, screen) in screens() {
        for (scheme, dark) in [("light", false), ("dark", true)] {
            let mut ui = launch(page, dark, screen.vm.clone());
            if let Some((label, value)) = screen.input {
                fill(&mut ui.t, label, value);
            }
            if let Some(name) = screen.click {
                let at = named_at(&ui.t, name);
                click(&mut ui.t, at);
            }
            screenshot(&mut ui.t, &format!("{name}-{scheme}"));
        }
    }
}

#[test]
fn rejected_url_is_not_saved_and_shows_why() {
    let mut ui = launch(
        Page::Settings,
        false,
        ViewModel {
            general_settings: Some(custom_settings()),
            ..Default::default()
        },
    );
    fill(&mut ui.t, "Auth URL", "firezone.example.com");
    assert!(texts(&ui.t).contains(&"Enter a valid http:// or https:// URL".to_owned()));
    assert!(ui.requests.try_recv().is_err());

    fill(&mut ui.t, "Auth URL", "https://other.example.com");
    assert_eq!(
        ui.requests.try_recv().unwrap(),
        Request::ApplySettings(SettingsChange {
            control_plane: Some(ControlPlane::Custom),
            auth_url: Some("https://other.example.com".into()),
            ..Default::default()
        })
    );
    assert!(!texts(&ui.t).contains(&"Enter a valid http:// or https:// URL".to_owned()));
}

#[test]
fn toggles_save_and_managed_ones_do_not() {
    let settings = GeneralSettings {
        connect_on_start_is_managed: true,
        ..general_settings()
    };
    let mut ui = launch(
        Page::Settings,
        false,
        ViewModel {
            general_settings: Some(settings),
            ..Default::default()
        },
    );
    let toggle_x = 851.;
    let y = text_at(&ui.t, "Start on login").1;
    click(&mut ui.t, (toggle_x, y));
    assert_eq!(
        ui.requests.try_recv().unwrap(),
        Request::ApplySettings(SettingsChange {
            start_on_login: Some(false),
            ..Default::default()
        })
    );
    let y = text_at(&ui.t, "Connect on start").1;
    click(&mut ui.t, (toggle_x, y));
    assert!(ui.requests.try_recv().is_err());
    assert!(texts(&ui.t).contains(&"Some settings are managed by your organization.".to_owned()));
}

#[test]
fn picking_custom_shows_the_url_fields() {
    let mut ui = launch(
        Page::Settings,
        false,
        ViewModel {
            general_settings: Some(general_settings()),
            ..Default::default()
        },
    );
    assert!(!texts(&ui.t).contains(&"Auth URL".to_owned()));
    let select = named_at(&ui.t, "Firezone Cloud (US)");
    click(&mut ui.t, select);
    let custom = named_at(&ui.t, "Custom");
    click(&mut ui.t, custom);
    assert_eq!(
        ui.requests.try_recv().unwrap(),
        Request::ApplySettings(SettingsChange {
            control_plane: Some(ControlPlane::Custom),
            auth_url: Some("https://app.firezone.dev/".into()),
            api_url: Some("wss://api.firezone.dev/".into()),
            ..Default::default()
        })
    );
    assert!(
        texts(&ui.t).contains(&"Auth URL".to_owned()),
        "the page keeps Custom until the user enters URLs"
    );
}

#[test]
fn reset_asks_first() {
    let mut ui = launch(
        Page::Settings,
        false,
        ViewModel {
            general_settings: Some(general_settings()),
            ..Default::default()
        },
    );
    let reset = named_at(&ui.t, "Reset to Defaults");
    click(&mut ui.t, reset);
    let cancel = named_at(&ui.t, "Cancel");
    click(&mut ui.t, cancel);
    assert!(!texts(&ui.t).contains(&"Reset settings to defaults?".to_owned()));
    assert!(ui.requests.try_recv().is_err());

    click(&mut ui.t, reset);
    let confirm = named_at(&ui.t, "Reset");
    click(&mut ui.t, confirm);
    assert_eq!(ui.requests.try_recv().unwrap(), Request::ResetSettings);
}

#[test]
fn sidebar_navigation_and_device_trust_tab() {
    let mut ui = launch(Page::Overview, false, ViewModel::default());
    assert!(!texts(&ui.t).contains(&"Device Trust".to_owned()));
    let diagnostics = named_at(&ui.t, "Diagnostics");
    click(&mut ui.t, diagnostics);
    assert!(texts(&ui.t).contains(&"Log Filter".to_owned()));

    ui.vm.set(ViewModel {
        certificate: Some(certificate()),
        ..Default::default()
    });
    settle(&mut ui.t);
    let device_trust = named_at(&ui.t, "Device Trust");
    click(&mut ui.t, device_trust);
    assert!(
        texts(&ui.t)
            .contains(&"Issued by DC=com, DC=example, CN=Example Corp Issuing CA 1".to_owned())
    );
}

#[test]
fn controller_roundtrip() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let Ui {
        mut t,
        vm,
        mut requests,
    } = launch(Page::Overview, false, ViewModel::default());
    let (vm_tx, vm_rx) = mpsc::unbounded_channel();

    // Controller: a tokio task outside the UI thread.
    rt.spawn(async move {
        let mut model = ViewModel {
            session: Some(Session::SignedOut),
            ..Default::default()
        };
        vm_tx.send(model.clone()).unwrap();
        while let Some(req) = requests.recv().await {
            if req == Request::SignIn {
                model.session = Some(Session::SignedIn {
                    account_slug: "example-corp".into(),
                    actor_name: "Jane Doe".into(),
                });
                vm_tx.send(model.clone()).unwrap();
            }
        }
    });
    t.run_in(|| spawn(apply_updates(vm_rx, vm)));

    wait_for(&mut t, |t| texts(t).contains(&"Sign in".to_owned()));
    let sign_in = named_at(&t, "Sign in");
    click(&mut t, sign_in);
    wait_for(&mut t, |t| texts(t).iter().any(|s| s.contains("Jane Doe")));
    assert!(matches!(vm.peek().session, Some(Session::SignedIn { .. })));
}

fn wait_for(t: &mut TestingRunner, cond: impl Fn(&TestingRunner) -> bool) {
    for _ in 0..200 {
        t.handle_events_immediately();
        t.sync_and_update();
        if cond(t) {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("condition not met; texts: {:?}", texts(t));
}

#[derive(Default)]
struct MemoryClipboard(String);

impl copypasta::ClipboardProvider for MemoryClipboard {
    fn get_contents(&mut self) -> Result<String, Box<dyn Error + Send + Sync>> {
        Ok(self.0.clone())
    }
    fn set_contents(&mut self, c: String) -> Result<(), Box<dyn Error + Send + Sync>> {
        self.0 = c;
        Ok(())
    }
}
