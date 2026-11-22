//! Renders every screen of the window to `screenshots/` and drives the pages like a user.

use std::{collections::HashMap, path::PathBuf, time::Duration};

use freya_testing::prelude::*;
use tokio::sync::mpsc;

use super::*;
use crate::{
    settings::{ControlPlane, DeveloperSettingsViewModel, SignInSettingsViewModel},
    view::X509DetailField,
};

#[test]
fn screenshots() {
    for (name, page, screen) in screens() {
        for (scheme, theme) in [
            ("light", PreferredTheme::Light),
            ("dark", PreferredTheme::Dark),
        ] {
            if screen.light_only && theme == PreferredTheme::Dark {
                continue;
            }

            let mut window = Window::open(page, theme, screen.view_model.clone());
            if let Some((label, value)) = screen.input {
                window.fill(label, value);
            }
            if let Some(name) = screen.click {
                window.click_named(name);
            }

            window.screenshot(&format!("{name}-{scheme}"));
        }
    }
}

#[test]
fn a_rejected_url_is_not_saved_and_says_why() {
    let mut window = Window::open(
        Page::Settings,
        PreferredTheme::Light,
        settings(custom_settings()),
    );

    window.fill("Auth URL", "firezone.example.com");

    assert!(window.shows("Enter a valid http:// or https:// URL"));
    assert!(window.no_request());

    window.fill("Auth URL", "https://other.example.com");

    let ControllerRequest::ApplyClientSettings(form) = window.next_request() else {
        panic!("expected the settings to be saved");
    };
    assert_eq!(
        *form,
        ClientSettingsForm {
            control_plane: Some(ControlPlane::Custom),
            auth_url: Some("https://other.example.com".to_owned()),
            ..Default::default()
        }
    );
    assert!(!window.shows("Enter a valid http:// or https:// URL"));
}

#[test]
fn a_field_saves_when_it_loses_focus() {
    let mut window = Window::open(
        Page::Settings,
        PreferredTheme::Light,
        settings(general_settings()),
    );

    window.type_into("Account slug", "other-corp");
    window.click_at((350., 450.));

    let ControllerRequest::ApplyClientSettings(form) = window.next_request() else {
        panic!("expected the settings to be saved");
    };
    assert_eq!(form.account_slug.as_deref(), Some("other-corp"));
}

#[test]
fn escape_reverts_a_field() {
    let mut window = Window::open(
        Page::Settings,
        PreferredTheme::Light,
        settings(general_settings()),
    );

    window.type_into("Account slug", "other-corp");
    window.t.press_key(Key::Named(NamedKey::Escape));
    window.settle();

    assert!(window.shows_input("example-corp"));
    assert!(window.no_request());
}

#[test]
fn an_invalid_log_filter_is_not_saved_and_says_why() {
    let mut window = Window::open(
        Page::Diagnostics,
        PreferredTheme::Light,
        ViewModel {
            log_filter: Some(log_filter()),
            ..Default::default()
        },
    );

    window.fill("Log Filter", "info,connlib=nonsense");

    assert!(
        window
            .texts()
            .iter()
            .any(|t| t.starts_with("Invalid log filter"))
    );
    assert!(window.no_request());
}

#[test]
fn toggles_save_and_managed_ones_do_not() {
    let mut window = Window::open(
        Page::Settings,
        PreferredTheme::Light,
        settings(GeneralSettingsViewModel {
            connect_on_start_is_managed: true,
            ..general_settings()
        }),
    );

    window.click_named("Start on login");

    let ControllerRequest::ApplyClientSettings(form) = window.next_request() else {
        panic!("expected the settings to be saved");
    };
    assert_eq!(form.start_on_login, Some(false));

    window.click_named("Connect on start");

    assert!(window.no_request());
    assert!(window.shows("Some settings are managed by your organization."));
}

#[test]
fn picking_custom_shows_the_url_fields() {
    let mut window = Window::open(
        Page::Settings,
        PreferredTheme::Light,
        settings(general_settings()),
    );
    assert!(!window.shows("Auth URL"));

    window.click_named("Firezone Cloud (US)");
    window.click_named("Custom");

    let ControllerRequest::ApplyClientSettings(form) = window.next_request() else {
        panic!("expected the settings to be saved");
    };
    assert_eq!(
        *form,
        ClientSettingsForm {
            control_plane: Some(ControlPlane::Custom),
            auth_url: Some("https://app.firezone.dev/".to_owned()),
            api_url: Some("wss://api.firezone.dev/".to_owned()),
            ..Default::default()
        }
    );
    assert!(
        window.shows("Auth URL"),
        "the page keeps Custom until the user enters URLs"
    );
}

#[test]
fn reset_asks_first() {
    let mut window = Window::open(
        Page::Settings,
        PreferredTheme::Light,
        settings(general_settings()),
    );

    window.click_named("Reset to Defaults");
    window.click_named("Cancel");

    assert!(!window.shows("Reset settings to defaults?"));
    assert!(window.no_request());

    window.click_named("Reset to Defaults");
    window.t.press_key(Key::Named(NamedKey::Escape));
    window.settle();

    assert!(!window.shows("Reset settings to defaults?"));

    window.click_named("Reset to Defaults");
    window.click_named("Reset");

    assert!(matches!(
        window.next_request(),
        ControllerRequest::ResetClientSettings
    ));
}

#[test]
fn the_sidebar_navigates_and_shows_device_trust_with_a_certificate() {
    let mut window = Window::open(Page::Overview, PreferredTheme::Light, ViewModel::default());
    assert!(!window.shows("Device Trust"));

    window.click_named("Diagnostics");

    assert!(window.shows("Log Filter"));

    window.ui.view_model.set(ViewModel {
        certificate: Some(certificate()),
        ..Default::default()
    });
    window.settle();
    window.click_named("Device Trust");

    assert!(window.shows("Issued by DC=com, DC=example, CN=Example Corp Issuing CA 1"));
}

#[test]
fn seven_clicks_on_the_logo_unlock_the_developer_settings() {
    let mut window = Window::open(Page::About, PreferredTheme::Light, ViewModel::default());

    for _ in 0..6 {
        window.click_named("Firezone Logo");
    }

    assert!(window.no_request());

    window.click_named("Firezone Logo");

    assert!(matches!(
        window.next_request(),
        ControllerRequest::SetDeveloperSettingsUnlocked(true)
    ));
}

#[test]
fn signing_in_asks_the_controller() {
    let mut window = Window::open(
        Page::Overview,
        PreferredTheme::Light,
        ViewModel {
            session: Some(SessionViewModel::SignedOut),
            ..Default::default()
        },
    );

    window.click_named("Sign in");

    assert!(matches!(window.next_request(), ControllerRequest::SignIn));
}

#[derive(Default)]
struct Screen {
    view_model: ViewModel,
    light_only: bool,
    click: Option<&'static str>,
    input: Option<(&'static str, &'static str)>,
}

/// Every screen the window can show, in the states the screenshots capture.
fn screens() -> Vec<(&'static str, Page, Screen)> {
    let logs = Some(FileCount {
        bytes: 3_400_000,
        files: 12,
    });

    vec![
        (
            "overview-signed-out",
            Page::Overview,
            session(SessionViewModel::SignedOut),
        ),
        (
            "overview-loading",
            Page::Overview,
            session(SessionViewModel::Loading),
        ),
        (
            "overview-signed-in",
            Page::Overview,
            session(SessionViewModel::SignedIn {
                account_slug: "example-corp".to_owned(),
                actor_name: "Jane Doe".to_owned(),
            }),
        ),
        (
            "general-settings",
            Page::Settings,
            Screen {
                view_model: settings(general_settings()),
                ..Default::default()
            },
        ),
        (
            "general-settings-custom",
            Page::Settings,
            Screen {
                view_model: settings(custom_settings()),
                ..Default::default()
            },
        ),
        (
            "general-settings-invalid-url",
            Page::Settings,
            Screen {
                view_model: settings(custom_settings()),
                input: Some(("Auth URL", "firezone.example.com")),
                ..Default::default()
            },
        ),
        (
            "general-settings-pending-sign-in",
            Page::Settings,
            Screen {
                view_model: settings(GeneralSettingsViewModel {
                    signed_in_with: Some(SignInSettingsViewModel {
                        account_slug: "example-corp".to_owned(),
                        control_plane: ControlPlane::CloudEu,
                        auth_url: "https://eu.app.firezone.dev/".to_owned(),
                        api_url: "wss://eu.api.firezone.dev/".to_owned(),
                    }),
                    ..general_settings()
                }),
                ..Default::default()
            },
        ),
        (
            "general-settings-managed",
            Page::Settings,
            Screen {
                view_model: settings(GeneralSettingsViewModel {
                    account_slug_is_managed: true,
                    start_on_login_is_managed: true,
                    connect_on_start_is_managed: true,
                    control_plane: ControlPlane::CloudEu,
                    auth_url: "https://eu.app.firezone.dev/".to_owned(),
                    auth_url_is_managed: true,
                    api_url: "wss://eu.api.firezone.dev/".to_owned(),
                    api_url_is_managed: true,
                    ..general_settings()
                }),
                ..Default::default()
            },
        ),
        (
            "device-trust-happy",
            Page::DeviceTrust,
            Screen {
                view_model: ViewModel {
                    certificate: Some(certificate()),
                    ..Default::default()
                },
                ..Default::default()
            },
        ),
        ("diagnostics-no-logs", Page::Diagnostics, Screen::default()),
        (
            "diagnostics",
            Page::Diagnostics,
            Screen {
                view_model: ViewModel {
                    log_count: logs.clone(),
                    log_filter: Some(log_filter()),
                    ..Default::default()
                },
                ..Default::default()
            },
        ),
        (
            "diagnostics-clear-confirmation",
            Page::Diagnostics,
            Screen {
                view_model: ViewModel {
                    log_count: Some(FileCount {
                        bytes: 3_400_000,
                        files: 17,
                    }),
                    log_filter: Some(log_filter()),
                    ..Default::default()
                },
                click: Some("Clear Logs"),
                ..Default::default()
            },
        ),
        (
            "settings-reset-confirmation",
            Page::Settings,
            Screen {
                view_model: settings(general_settings()),
                click: Some("Reset to Defaults"),
                ..Default::default()
            },
        ),
        (
            "diagnostics-managed",
            Page::Diagnostics,
            Screen {
                view_model: ViewModel {
                    log_count: logs,
                    log_filter: Some(LogFilterViewModel {
                        log_filter: "debug".to_owned(),
                        log_filter_is_managed: true,
                    }),
                    ..Default::default()
                },
                ..Default::default()
            },
        ),
        ("about", Page::About, Screen::default()),
        (
            "developer-settings",
            Page::Developer,
            Screen {
                view_model: ViewModel {
                    developer_settings: Some(DeveloperSettingsViewModel {
                        unlocked: true,
                        force_relayed_connections: false,
                    }),
                    ..Default::default()
                },
                light_only: true,
                ..Default::default()
            },
        ),
    ]
}

fn session(session: SessionViewModel) -> Screen {
    Screen {
        view_model: ViewModel {
            session: Some(session),
            ..Default::default()
        },
        ..Default::default()
    }
}

fn settings(general_settings: GeneralSettingsViewModel) -> ViewModel {
    ViewModel {
        general_settings: Some(general_settings),
        ..Default::default()
    }
}

fn general_settings() -> GeneralSettingsViewModel {
    GeneralSettingsViewModel {
        start_minimized: true,
        start_on_login: true,
        start_on_login_is_managed: false,
        connect_on_start: false,
        connect_on_start_is_managed: false,
        account_slug: "example-corp".to_owned(),
        account_slug_is_managed: false,
        control_plane: ControlPlane::CloudUs,
        auth_url: "https://app.firezone.dev/".to_owned(),
        auth_url_is_managed: false,
        api_url: "wss://api.firezone.dev/".to_owned(),
        api_url_is_managed: false,
        custom_auth_url: "https://app.firezone.dev/".to_owned(),
        custom_api_url: "wss://api.firezone.dev/".to_owned(),
        signed_in_with: None,
    }
}

fn custom_settings() -> GeneralSettingsViewModel {
    GeneralSettingsViewModel {
        control_plane: ControlPlane::Custom,
        auth_url: "https://firezone.example.com/".to_owned(),
        api_url: "wss://api.firezone.example.com/".to_owned(),
        ..general_settings()
    }
}

fn log_filter() -> LogFilterViewModel {
    LogFilterViewModel {
        log_filter: "info".to_owned(),
        log_filter_is_managed: false,
    }
}

fn certificate() -> X509Certificate {
    const CN: &str = "dev.firezone.device-trust";

    X509Certificate {
        fields: [
            ("Common Name", CN.to_owned()),
            ("Subject", format!("O=Example Corp, CN={CN}")),
            ("Issuer", "DC=com, DC=example, CN=Example Corp Issuing CA 1".to_owned()),
            ("MDM Device ID", "9a1c7d4e-5f60-4b28-8c3a-2d5e7f9b0c14".to_owned()),
            ("Device Serial", "PF2X9K7L".to_owned()),
            (
                "Serial Number",
                "3a:68:e8:18:bf:83:6b:20:c4:37:16:ec:96:d2:7a:a4".to_owned(),
            ),
            ("Not Before", "Mar 12 09:12:44 2026 +00:00".to_owned()),
            ("Not After", "Jun 14 09:12:44 2028 +00:00".to_owned()),
            ("Signing Algorithm", "SHA256withRSA".to_owned()),
            (
                "SHA-256 Fingerprint",
                "90:E4:45:C9:E2:8E:8F:5B:57:D2:30:90:8C:6F:B2:3D:CE:A1:61:CA:96:3E:BF:B2:8E:E7:3D:A9:CF:70:DD:B7".to_owned(),
            ),
        ]
        .into_iter()
        .map(|(label, value)| X509DetailField {
            label: label.to_owned(),
            value: Some(value),
            problem: None,
        })
        .collect(),
    }
}

/// The window, with what it asks of the Controller.
struct Window {
    t: TestingRunner,
    ui: Ui,
    requests: mpsc::Receiver<ControllerRequest>,
    rt: tokio::runtime::Runtime,
}

impl Window {
    fn open(page: Page, theme: PreferredTheme, view_model: ViewModel) -> Self {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_time()
            .build()
            .unwrap();
        let (tx, requests) = mpsc::channel(16);
        let requests_rt = rt.handle().clone();
        let (mut t, ui) = TestingRunner::new(
            app,
            (WINDOW_SIZE.0 as f32, WINDOW_SIZE.1 as f32).into(),
            move |_| {
                let mut ui = Ui::new(
                    Requests {
                        tx,
                        rt: requests_rt,
                        inject_faults: false,
                    },
                    Build {
                        version: "1.0.0",
                        git_sha: "0000000000000000000000000000000000000000",
                    },
                );
                ui.view_model.set(view_model);
                ui.page.set(page);
                GlobalContexts::get().insert_context(ui.clone());

                ui
            },
            1.,
        );
        for (family, bytes) in FONTS {
            // One font per call, because `set_fonts` takes a map keyed by family.
            t.set_fonts(HashMap::from([(family, bytes)]));
        }
        t.set_default_fonts(&[SANS.into()]);
        t.animation_clock().disable();
        t.run_in(|| Platform::get().current_window().preferred_theme.set(theme));
        t.sync_and_update();

        let mut window = Self {
            t,
            ui,
            requests,
            rt,
        };
        window.settle();

        window
    }

    fn settle(&mut self) {
        self.t
            .poll(Duration::from_millis(5), Duration::from_millis(60));
    }

    fn screenshot(&mut self, name: &str) {
        let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../screenshots");

        std::fs::write(
            directory.join(format!("{name}.png")),
            self.t.render().as_bytes(),
        )
        .unwrap();
    }

    /// The next request, skipping the state refresh every window asks for when it opens.
    fn next_request(&mut self) -> ControllerRequest {
        loop {
            let request = self
                .rt
                .block_on(async {
                    tokio::time::timeout(Duration::from_secs(1), self.requests.recv()).await
                })
                .expect("no request within 1s")
                .unwrap();

            if !matches!(request, ControllerRequest::UpdateState) {
                return request;
            }
        }
    }

    fn no_request(&mut self) -> bool {
        loop {
            match self.rt.block_on(async {
                tokio::time::timeout(Duration::from_millis(200), self.requests.recv()).await
            }) {
                Ok(Some(ControllerRequest::UpdateState)) => continue,
                Ok(Some(_)) => return false,
                Ok(None) | Err(_) => return true,
            }
        }
    }

    fn texts(&self) -> Vec<String> {
        self.t.find_many(|_, element| {
            Label::try_downcast(element)
                .map(|label| label.text.to_string())
                .or_else(|| {
                    Paragraph::try_downcast(element).map(|paragraph| {
                        paragraph
                            .spans
                            .iter()
                            .map(|span| span.text.as_ref())
                            .collect()
                    })
                })
        })
    }

    fn shows(&self, text: &str) -> bool {
        self.texts().iter().any(|t| t == text)
    }

    fn shows_input(&self, text: &str) -> bool {
        self.named_at(text).is_some()
    }

    /// The centre of the element named `name`, like `getByRole(_, { name })`.
    fn named_at(&self, name: &str) -> Option<(f64, f64)> {
        self.t
            .find(|node, element| {
                Rect::try_downcast(element)
                    .filter(|rect| rect.accessibility.builder.label() == Some(name))
                    .map(|_| node.layout().area.center())
            })
            .map(|centre| (centre.x as f64, centre.y as f64))
    }

    fn click_named(&mut self, name: &str) {
        let at = self
            .named_at(name)
            .unwrap_or_else(|| panic!("nothing named {name:?} in {:?}", self.texts()));

        self.click_at(at);
    }

    fn click_at(&mut self, at: (f64, f64)) {
        // `click_cursor` presses where the pointer is not, so hover handlers would not run.
        self.t.move_cursor(at);
        self.t.click_cursor(at);
        self.settle();
    }

    /// Replaces what the field labelled `label` holds.
    fn type_into(&mut self, label: &str, value: &str) {
        self.click_named(label);
        self.t.send_event(PlatformEvent::Keyboard {
            name: KeyboardEventName::KeyDown,
            key: Key::Character("a".into()),
            code: Code::KeyA,
            modifiers: if cfg!(target_os = "macos") {
                Modifiers::META
            } else {
                Modifiers::CONTROL
            },
        });
        self.t.write_text(value);
        self.settle();
    }

    /// Replaces what the field labelled `label` holds and presses Enter, like `userEvent.fill`.
    fn fill(&mut self, label: &str, value: &str) {
        self.type_into(label, value);
        self.t.press_key(Key::Named(NamedKey::Enter));
        self.settle();
    }
}
