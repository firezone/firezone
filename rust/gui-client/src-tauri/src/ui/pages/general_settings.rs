use freya::prelude::*;

use crate::{
    settings::{ControlPlane, GeneralSettingsViewModel, SignInSettingsViewModel},
    ui::{
        Ui,
        components::{
            Icon, ScrollPage, Select, TextSetting, Variant, border_top, button, card,
            confirmation_dialog, managed_notice, note, pal, section, setting_row, toggle,
        },
    },
    view::ClientSettingsForm,
};

const CONTROL_PLANES: [ControlPlane; 3] = [
    ControlPlane::CloudUs,
    ControlPlane::CloudEu,
    ControlPlane::Custom,
];
const CONTROL_PLANE_NAMES: &[&str] = &["Firezone Cloud (US)", "Firezone Cloud (EU)", "Custom"];

#[derive(PartialEq)]
pub(crate) struct GeneralSettings(pub(crate) Option<GeneralSettingsViewModel>);

impl Component for GeneralSettings {
    fn render(&self) -> impl IntoElement {
        let requests = Ui::get().requests;
        let saved = self.0.clone().unwrap_or_else(not_loaded);
        let mut confirm_reset = use_state(|| false);
        // Custom with a cloud control plane's URLs is saved as that control plane, so the page
        // keeps the choice until the user enters URLs of their own.
        let mut custom_picked = use_state(|| false);
        let (account_slug, mut auth_url, mut api_url) = (
            use_state(String::new),
            use_state(String::new),
            use_state(String::new),
        );

        let control_plane = if custom_picked() {
            ControlPlane::Custom
        } else {
            saved.control_plane
        };
        let (custom_auth_url, custom_api_url) = match saved.control_plane {
            ControlPlane::Custom => (saved.auth_url.clone(), saved.api_url.clone()),
            ControlPlane::CloudUs | ControlPlane::CloudEu => {
                (saved.custom_auth_url.clone(), saved.custom_api_url.clone())
            }
        };

        let saved_sign_in = SignInSettingsViewModel {
            account_slug: saved.account_slug.clone(),
            control_plane: saved.control_plane,
            auth_url: saved.auth_url.clone(),
            api_url: saved.api_url.clone(),
        };
        let draft_sign_in = SignInSettingsViewModel {
            account_slug: account_slug.read().clone(),
            control_plane,
            auth_url: if control_plane == ControlPlane::Custom {
                auth_url.read().clone()
            } else {
                custom_auth_url.clone()
            },
            api_url: if control_plane == ControlPlane::Custom {
                api_url.read().clone()
            } else {
                custom_api_url.clone()
            },
        };
        let sign_in_pending = saved.signed_in_with.as_ref().is_some_and(|signed_in_with| {
            differs(&saved_sign_in, signed_in_with) || differs(&draft_sign_in, signed_in_with)
        });

        let save = {
            let requests = requests.clone();
            move |form: ClientSettingsForm| requests.apply_client_settings(form)
        };
        let select_control_plane = {
            let (save, auth, api) = (
                save.clone(),
                custom_auth_url.clone(),
                custom_api_url.clone(),
            );
            move |i: usize| {
                let control_plane = CONTROL_PLANES[i];
                let picked_custom = control_plane == ControlPlane::Custom;
                custom_picked.set(picked_custom);
                auth_url.set(auth.clone());
                api_url.set(api.clone());
                save(ClientSettingsForm {
                    control_plane: Some(control_plane),
                    auth_url: picked_custom.then(|| auth.clone()),
                    api_url: picked_custom.then(|| api.clone()),
                    ..Default::default()
                });
            }
        };
        let text_setting = |label,
                            value: &String,
                            text,
                            managed,
                            validate,
                            form: fn(String) -> ClientSettingsForm| {
            let save = save.clone();
            TextSetting {
                label,
                value: value.clone(),
                text,
                managed,
                mono: false,
                validate,
                save: Callback::new(move |value| {
                    save(form(value));
                    None
                }),
            }
            .into_element()
        };
        let toggle_row = |label, checked, managed, form: fn(bool) -> ClientSettingsForm| {
            let save = save.clone();
            toggle(label, checked, managed, move |value| save(form(value)))
        };

        let urls_managed = saved.auth_url_is_managed || saved.api_url_is_managed;
        let mut sign_in = vec![
            text_setting(
                "Account slug",
                &saved.account_slug,
                account_slug,
                saved.account_slug_is_managed,
                None,
                |account_slug| ClientSettingsForm {
                    account_slug: Some(account_slug),
                    ..Default::default()
                },
            ),
            setting_row(
                "Control plane",
                urls_managed,
                true,
                Select {
                    options: CONTROL_PLANE_NAMES,
                    selected: CONTROL_PLANES
                        .iter()
                        .position(|c| *c == control_plane)
                        .unwrap_or(2),
                    managed: urls_managed,
                    on_change: EventHandler::new(select_control_plane),
                },
                None,
            ),
        ];
        if control_plane == ControlPlane::Custom {
            sign_in.push(text_setting(
                "Auth URL",
                &custom_auth_url,
                auth_url,
                saved.auth_url_is_managed,
                Some((&["http", "https"], "Enter a valid http:// or https:// URL")),
                |auth_url| ClientSettingsForm {
                    control_plane: Some(ControlPlane::Custom),
                    auth_url: Some(auth_url),
                    ..Default::default()
                },
            ));
            sign_in.push(text_setting(
                "API URL",
                &custom_api_url,
                api_url,
                saved.api_url_is_managed,
                Some((&["ws", "wss"], "Enter a valid ws:// or wss:// URL")),
                |api_url| ClientSettingsForm {
                    control_plane: Some(ControlPlane::Custom),
                    api_url: Some(api_url),
                    ..Default::default()
                },
            ));
        }
        let startup = [
            toggle_row("Start minimized", saved.start_minimized, false, |value| {
                ClientSettingsForm {
                    start_minimized: Some(value),
                    ..Default::default()
                }
            }),
            toggle_row(
                "Start on login",
                saved.start_on_login,
                saved.start_on_login_is_managed,
                |value| ClientSettingsForm {
                    start_on_login: Some(value),
                    ..Default::default()
                },
            ),
            toggle_row(
                "Connect on start",
                saved.connect_on_start,
                saved.connect_on_start_is_managed,
                |value| ClientSettingsForm {
                    connect_on_start: Some(value),
                    ..Default::default()
                },
            ),
        ];
        let any_managed = saved.account_slug_is_managed
            || urls_managed
            || saved.start_on_login_is_managed
            || saved.connect_on_start_is_managed;
        let pending = sign_in_pending.then(|| {
            note(
                Icon::Information,
                "Changes to account slug and control plane only take effect on the next sign-in.",
            )
        });

        let p = pal();
        rect()
            .expanded()
            .child(ScrollPage(
                rect()
                    .width(Size::fill())
                    .spacing(20.)
                    .child(section("Sign-in", card(sign_in), pending))
                    .child(section(
                        "Startup",
                        card(startup),
                        any_managed.then(managed_notice),
                    ))
                    .child(
                        rect()
                            .width(Size::fill())
                            .horizontal()
                            .main_align(Alignment::End)
                            .padding((13., 0., 0., 0.))
                            .border(border_top(p.border))
                            .child(
                                button("Reset to Defaults", Variant::Secondary)
                                    .on_press(move |_| confirm_reset.set(true)),
                            ),
                    )
                    .into(),
            ))
            .maybe_child(confirm_reset().then(|| {
                confirmation_dialog(
                    "Reset settings to defaults?",
                    "Reset",
                    move || confirm_reset.set(false),
                    move || {
                        confirm_reset.set(false);
                        custom_picked.set(false);
                        requests.reset_client_settings();
                    },
                )
            }))
    }
}

/// What the page shows until the Controller sends the settings.
fn not_loaded() -> GeneralSettingsViewModel {
    GeneralSettingsViewModel {
        start_minimized: true,
        start_on_login: false,
        start_on_login_is_managed: false,
        connect_on_start: false,
        connect_on_start_is_managed: false,
        account_slug: String::new(),
        account_slug_is_managed: false,
        control_plane: ControlPlane::Custom,
        auth_url: String::new(),
        auth_url_is_managed: false,
        api_url: String::new(),
        api_url_is_managed: false,
        custom_auth_url: String::new(),
        custom_api_url: String::new(),
        signed_in_with: None,
    }
}

/// Cloud control planes compare by name, Custom ones by their URLs.
fn differs(sign_in: &SignInSettingsViewModel, signed_in_with: &SignInSettingsViewModel) -> bool {
    let normalize = |url: &str| url::Url::parse(url).map_or_else(|_| url.to_owned(), String::from);

    sign_in.account_slug.trim() != signed_in_with.account_slug
        || match sign_in.control_plane {
            ControlPlane::Custom => {
                normalize(&sign_in.auth_url) != normalize(&signed_in_with.auth_url)
                    || normalize(&sign_in.api_url) != normalize(&signed_in_with.api_url)
            }
            ControlPlane::CloudUs | ControlPlane::CloudEu => {
                sign_in.control_plane != signed_in_with.control_plane
            }
        }
}
