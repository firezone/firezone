//! The xilem screens: a left nav sidebar plus the five content pages, mirroring
//! `crate::iced::ui`. The Firezone look comes mostly from the app-wide
//! [`crate::xilem::theme::properties`] default-property set (installed via
//! `Xilem::with_default_properties`), so stock `text_button` / `text_input` /
//! `checkbox` / `label` already render themed. This module only applies
//! per-instance overrides via xilem 0.4's [`Style`] trait + `.prop`: primary
//! buttons, the active nav item, and secondary/warning/muted text. Still stock
//! are the toggles (plain checkboxes, not animated switches) and assets (no
//! logo/SVG icons/custom fonts) — see `mod.rs`.

use xilem::masonry::properties::types::{AsUnit, CrossAxisAlignment, MainAxisAlignment};
use xilem::style::{BorderWidth, CornerRadius, Padding, Style};
use xilem::view::{
    FlexExt as _, button, checkbox, flex_col, flex_row, label, sized_box, text_button, text_input,
};
use xilem::{AnyWidgetView, FontWeight, WidgetView};

use crate::GeneralSettingsForm;
use crate::controller::ControllerRequest;
use crate::xilem::state::{App, Route, Session};
use crate::xilem::theme;

const APP_VERSION: &str = env!("CARGO_PKG_VERSION");
const GIT_SHA: &str = match option_env!("FIREZONE_GIT_SHA") {
    Some(s) => s,
    None => "dev",
};

/// Send a request into the Controller, if the bridge has wired up the channel.
fn send(app: &App, req: ControllerRequest) {
    if let Some(tx) = &app.ctrl_tx {
        let _ = tx.send(req);
    } else {
        tracing::warn!("controller not started; dropping request");
    }
}

/// Brand-orange primary action button. Overrides the themed (secondary) button
/// default with the brand background, white label, and no border.
fn primary_button<F>(text: &str, on_press: F) -> impl WidgetView<App> + use<F>
where
    F: Fn(&mut App) + Send + Sync + 'static,
{
    button(
        label(text.to_owned()).color(theme::ON_BRAND),
        move |app: &mut App| on_press(app),
    )
    .background_color(theme::BRAND)
    .prop(BorderWidth::all(0.0))
}

/// A muted form-field label (overrides the default primary ink colour).
fn field_label(text: &str) -> impl WidgetView<App> + use<> {
    label(text.to_owned())
        .text_size(13.0)
        .color(theme::TEXT_SECONDARY)
}

/// Sidebar (surface) + the current page (on canvas, filling the rest).
pub fn root(app: &App) -> impl WidgetView<App> + use<> {
    flex_row((
        sized_box(sidebar(app.route))
            .width(200.0.px())
            .background_color(theme::SURFACE),
        sized_box(content(app))
            .background_color(theme::CANVAS)
            .flex(1.0),
    ))
    .cross_axis_alignment(CrossAxisAlignment::Fill)
    .main_axis_alignment(MainAxisAlignment::Start)
    .gap(0.0.px())
}

fn content(app: &App) -> Box<AnyWidgetView<App>> {
    match app.route {
        Route::Overview => overview(app).boxed(),
        Route::GeneralSettings => general_settings(app).boxed(),
        Route::AdvancedSettings => advanced_settings(app).boxed(),
        Route::Diagnostics => diagnostics(app).boxed(),
        Route::About => about().boxed(),
    }
}

fn sidebar(current: Route) -> impl WidgetView<App> + use<> {
    flex_col((
        nav_item("Overview", Route::Overview, current),
        nav_item("General settings", Route::GeneralSettings, current),
        nav_item("Advanced settings", Route::AdvancedSettings, current),
        nav_item("Diagnostics", Route::Diagnostics, current),
        nav_item("About", Route::About, current),
    ))
    .cross_axis_alignment(CrossAxisAlignment::Fill)
    .main_axis_alignment(MainAxisAlignment::Start)
    .gap(4.0.px())
    .prop(Padding::all(12.0))
}

fn nav_item(name: &str, route: Route, current: Route) -> impl WidgetView<App> + use<> {
    let active = route == current;
    // Active page: raised surface + brand text. Otherwise blends into the
    // sidebar with muted text. Borderless + tighter than a normal button.
    let (bg, fg) = if active {
        (theme::SURFACE_RAISED, theme::BRAND_HOVER)
    } else {
        (theme::SURFACE, theme::TEXT_SECONDARY)
    };
    button(
        label(name.to_owned()).text_size(14.0).color(fg),
        move |app: &mut App| app.route = route,
    )
    .background_color(bg)
    .prop(BorderWidth::all(0.0))
    .prop(CornerRadius::all(6.0))
    .prop(Padding::from_vh(8.0, 12.0))
}

fn overview(app: &App) -> impl WidgetView<App> + use<> {
    let session: Box<AnyWidgetView<App>> = match &app.session {
        Session::SignedOut => flex_col((
            label("You can sign in from the taskbar icon, or with the button below.")
                .text_size(14.0)
                .color(theme::TEXT_SECONDARY),
            primary_button("Sign in", |app: &mut App| {
                send(app, ControllerRequest::SignIn);
            }),
        ))
        .gap(12.0.px())
        .cross_axis_alignment(CrossAxisAlignment::Center)
        .boxed(),
        Session::Loading => label("Signing in…")
            .text_size(14.0)
            .color(theme::TEXT_SECONDARY)
            .boxed(),
        Session::SignedIn {
            account_slug,
            actor_name,
        } => flex_col((
            label(format!("Signed in to {account_slug} as {actor_name}."))
                .text_size(14.0)
                .color(theme::TEXT_SECONDARY),
            text_button("Sign out", |app: &mut App| {
                send(app, ControllerRequest::SignOut);
            }),
        ))
        .gap(12.0.px())
        .cross_axis_alignment(CrossAxisAlignment::Center)
        .boxed(),
    };

    flex_col((
        label("Firezone").text_size(40.0).weight(FontWeight::BOLD),
        session,
    ))
    .gap(16.0.px())
    .cross_axis_alignment(CrossAxisAlignment::Center)
    .main_axis_alignment(MainAxisAlignment::Center)
}

fn general_settings(app: &App) -> impl WidgetView<App> + use<> {
    let s = &app.general_settings;
    flex_col((
        field_label("Account slug"),
        text_input(s.account_slug.clone(), |app: &mut App, v: String| {
            app.general_settings.account_slug = v;
        })
        .disabled(s.account_slug_is_managed),
        checkbox("Start minimized", s.start_minimized, |app: &mut App, v| {
            app.general_settings.start_minimized = v;
        }),
        checkbox("Start on login", s.start_on_login, |app: &mut App, v| {
            app.general_settings.start_on_login = v;
        }),
        checkbox(
            "Connect on start",
            s.connect_on_start,
            |app: &mut App, v| {
                app.general_settings.connect_on_start = v;
            },
        )
        .disabled(s.connect_on_start_is_managed),
        flex_row((
            primary_button("Save", |app: &mut App| {
                let g = &app.general_settings;
                let form = GeneralSettingsForm {
                    start_minimized: g.start_minimized,
                    start_on_login: g.start_on_login,
                    connect_on_start: g.connect_on_start,
                    account_slug: g.account_slug.clone(),
                };
                send(app, ControllerRequest::ApplyGeneralSettings(Box::new(form)));
            }),
            text_button("Reset to defaults", |app: &mut App| {
                send(app, ControllerRequest::ResetGeneralSettings);
            }),
        ))
        .gap(8.0.px()),
    ))
    .cross_axis_alignment(CrossAxisAlignment::Start)
    .main_axis_alignment(MainAxisAlignment::Start)
    .gap(10.0.px())
    .prop(Padding::all(24.0))
}

fn advanced_settings(app: &App) -> impl WidgetView<App> + use<> {
    let s = &app.advanced_settings;
    flex_col((
        label(
            "WARNING: these settings are for internal debugging only. Changing \
             them is unsupported and will likely break the client.",
        )
        .text_size(13.0)
        .color(theme::STATUS_WARN),
        field_label("Auth base URL"),
        text_input(s.auth_url.clone(), |app: &mut App, v: String| {
            app.advanced_settings.auth_url = v;
        })
        .disabled(s.auth_url_is_managed),
        field_label("API URL"),
        text_input(s.api_url.clone(), |app: &mut App, v: String| {
            app.advanced_settings.api_url = v;
        })
        .disabled(s.api_url_is_managed),
        field_label("Log filter"),
        text_input(s.log_filter.clone(), |app: &mut App, v: String| {
            app.advanced_settings.log_filter = v;
        })
        .disabled(s.log_filter_is_managed),
        flex_row((
            primary_button("Save", |app: &mut App| {
                match app.advanced_settings.to_settings() {
                    Some(advanced) => {
                        send(
                            app,
                            ControllerRequest::ApplyAdvancedSettings(Box::new(advanced)),
                        );
                    }
                    None => tracing::warn!("advanced settings: a URL failed to parse"),
                }
            }),
            text_button("Reset to defaults", |app: &mut App| {
                send(
                    app,
                    ControllerRequest::ApplyAdvancedSettings(Box::default()),
                );
            }),
        ))
        .gap(8.0.px()),
    ))
    .cross_axis_alignment(CrossAxisAlignment::Start)
    .main_axis_alignment(MainAxisAlignment::Start)
    .gap(10.0.px())
    .prop(Padding::all(24.0))
}

fn diagnostics(app: &App) -> impl WidgetView<App> + use<> {
    let count = &app.log_count;
    let megabytes = (count.bytes as f64) / 1_000_000.0;
    let summary = format!(
        "Log directory size: {} files, {megabytes:.1} MB",
        count.files
    );

    flex_col((
        label(summary).text_size(14.0).color(theme::TEXT_SECONDARY),
        flex_row((
            // Flips the flag; `entry::app_logic` runs the async dialog + zip in
            // a one-shot `task` view and clears the flag when done.
            text_button("Export Logs", |app: &mut App| {
                app.export_in_flight = true;
            }),
            text_button("Clear Logs", |app: &mut App| {
                let (cb_tx, _cb_rx) = tokio::sync::oneshot::channel();
                send(app, ControllerRequest::ClearLogs(cb_tx));
            }),
        ))
        .gap(12.0.px()),
    ))
    .gap(24.0.px())
    .cross_axis_alignment(CrossAxisAlignment::Center)
    .main_axis_alignment(MainAxisAlignment::Center)
}

fn about() -> impl WidgetView<App> + use<> {
    flex_col((
        label("Firezone").text_size(24.0).weight(FontWeight::BOLD),
        label(format!("Version {APP_VERSION}"))
            .text_size(14.0)
            .color(theme::TEXT_SECONDARY),
        label(format!("({})", &GIT_SHA[..GIT_SHA.len().min(8)]))
            .text_size(11.0)
            .color(theme::TEXT_MUTED),
        text_button("Documentation", |_app: &mut App| {
            let _ = open::that_detached("https://www.firezone.dev/kb");
        }),
    ))
    .gap(6.0.px())
    .cross_axis_alignment(CrossAxisAlignment::Center)
    .main_axis_alignment(MainAxisAlignment::Center)
}
