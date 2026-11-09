use freya::prelude::*;

use crate::{
    Bridge, ControlPlane, GeneralSettings, Request, SettingsChange, SignInSettings,
    components::{
        Icon, ScrollPage, Select, TextSetting, Variant, border_top, button, card,
        confirmation_dialog, managed_notice, note, section, setting_row, toggle,
    },
};

const PLANES: [ControlPlane; 3] = [
    ControlPlane::CloudUs,
    ControlPlane::CloudEu,
    ControlPlane::Custom,
];
const PLANE_NAMES: &[&str] = &["Firezone Cloud (US)", "Firezone Cloud (EU)", "Custom"];

#[derive(PartialEq)]
pub struct GeneralSettingsPage(pub GeneralSettings);

impl Component for GeneralSettingsPage {
    fn render(&self) -> impl IntoElement {
        let bridge = use_consume::<Bridge>();
        let saved = &self.0;
        let mut confirm_reset = use_state(|| false);
        // Custom with a cloud control plane's URLs is saved as that control plane, so the page
        // keeps the choice until the user enters URLs of their own.
        let mut custom_picked = use_state(|| false);
        let (slug, mut auth_url, mut api_url) = (
            use_state(String::new),
            use_state(String::new),
            use_state(String::new),
        );

        let control_plane = if custom_picked() {
            ControlPlane::Custom
        } else {
            saved.control_plane
        };
        let custom = saved.control_plane == ControlPlane::Custom;
        let custom_auth_url = if custom {
            &saved.auth_url
        } else {
            &saved.custom_auth_url
        }
        .clone();
        let custom_api_url = if custom {
            &saved.api_url
        } else {
            &saved.custom_api_url
        }
        .clone();

        let saved_sign_in = SignInSettings {
            account_slug: saved.account_slug.clone(),
            control_plane: saved.control_plane,
            auth_url: saved.auth_url.clone(),
            api_url: saved.api_url.clone(),
        };
        let draft_sign_in = SignInSettings {
            account_slug: slug.read().clone(),
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
        let sign_in_pending = saved
            .signed_in_with
            .as_ref()
            .is_some_and(|with| differs(&saved_sign_in, with) || differs(&draft_sign_in, with));

        let save = {
            let bridge = bridge.clone();
            move |change: SettingsChange| bridge.send(Request::ApplySettings(change))
        };
        let select_plane = {
            let (save, auth, api) = (
                save.clone(),
                custom_auth_url.clone(),
                custom_api_url.clone(),
            );
            move |i: usize| {
                let plane = PLANES[i];
                let picked_custom = plane == ControlPlane::Custom;
                custom_picked.set(picked_custom);
                auth_url.set(auth.clone());
                api_url.set(api.clone());
                save(SettingsChange {
                    control_plane: Some(plane),
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
                            change: fn(String) -> SettingsChange| {
            let save = save.clone();
            TextSetting {
                label,
                value: value.clone(),
                text,
                managed,
                mono: false,
                validate,
                on_save: EventHandler::new(move |v| save(change(v))),
            }
            .into_element()
        };
        let toggle_row = |label, checked, managed, change: fn(bool) -> SettingsChange| {
            let save = save.clone();
            setting_row(
                label,
                managed,
                true,
                toggle(checked, managed, move |v| save(change(v))),
                None,
            )
        };

        let urls_managed = saved.auth_url_is_managed || saved.api_url_is_managed;
        let mut sign_in = vec![
            text_setting(
                "Account slug",
                &saved.account_slug,
                slug,
                saved.account_slug_is_managed,
                None,
                |v| SettingsChange {
                    account_slug: Some(v),
                    ..Default::default()
                },
            ),
            setting_row(
                "Control plane",
                urls_managed,
                true,
                Select {
                    options: PLANE_NAMES,
                    selected: PLANES.iter().position(|p| *p == control_plane).unwrap_or(2),
                    managed: urls_managed,
                    on_change: EventHandler::new(select_plane),
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
                |v| SettingsChange {
                    control_plane: Some(ControlPlane::Custom),
                    auth_url: Some(v),
                    ..Default::default()
                },
            ));
            sign_in.push(text_setting(
                "API URL",
                &custom_api_url,
                api_url,
                saved.api_url_is_managed,
                Some((&["ws", "wss"], "Enter a valid ws:// or wss:// URL")),
                |v| SettingsChange {
                    control_plane: Some(ControlPlane::Custom),
                    api_url: Some(v),
                    ..Default::default()
                },
            ));
        }
        let startup = [
            toggle_row("Start minimized", saved.start_minimized, false, |v| {
                SettingsChange {
                    start_minimized: Some(v),
                    ..Default::default()
                }
            }),
            toggle_row(
                "Start on login",
                saved.start_on_login,
                saved.start_on_login_is_managed,
                |v| SettingsChange {
                    start_on_login: Some(v),
                    ..Default::default()
                },
            ),
            toggle_row(
                "Connect on start",
                saved.connect_on_start,
                saved.connect_on_start_is_managed,
                |v| SettingsChange {
                    connect_on_start: Some(v),
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

        let p = crate::components::pal();
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
                let bridge = bridge.clone();
                confirmation_dialog(
                    "Reset settings to defaults?",
                    "Reset",
                    move |_| confirm_reset.set(false),
                    move |_| {
                        confirm_reset.set(false);
                        custom_picked.set(false);
                        bridge.send(Request::ResetSettings);
                    },
                )
            }))
    }
}

/// Cloud control planes compare by name, Custom ones by their URLs.
fn differs(sign_in: &SignInSettings, signed_in_with: &SignInSettings) -> bool {
    let normalize = |url: &str| url::Url::parse(url).map_or_else(|_| url.to_owned(), String::from);
    sign_in.account_slug.trim() != signed_in_with.account_slug
        || match sign_in.control_plane {
            ControlPlane::Custom => {
                normalize(&sign_in.auth_url) != normalize(&signed_in_with.auth_url)
                    || normalize(&sign_in.api_url) != normalize(&signed_in_with.api_url)
            }
            plane => plane != signed_in_with.control_plane,
        }
}
