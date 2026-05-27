//! The xilem screens: a left nav sidebar plus the five content pages, mirroring
//! `crate::iced::ui`. This first cut favours xilem's idiomatic style (callbacks
//! mutate `&mut App` directly, or send a `ControllerRequest` via `App::ctrl_tx`)
//! over the iced port's bespoke design-system widgets, so it deliberately drops
//! the iced niceties (animated toggles, brand colours, logo/SVG assets,
//! "managed by administrator" hints) in favour of stock masonry widgets. Those
//! are styling polish, not blockers — see mod.rs.

use xilem::masonry::properties::types::{AsUnit, CrossAxisAlignment, MainAxisAlignment};
use xilem::view::{checkbox, flex_col, flex_row, label, sized_box, text_button, text_input};
use xilem::{AnyWidgetView, FontWeight, WidgetView};

use crate::GeneralSettingsForm;
use crate::controller::ControllerRequest;
use crate::xilem::state::{App, Route, Session};

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

/// Sidebar + the current page.
pub fn root(app: &App) -> impl WidgetView<App> + use<> {
    flex_row((
        sized_box(sidebar(app.route)).width(200.0.px()),
        content(app),
    ))
    .cross_axis_alignment(CrossAxisAlignment::Fill)
    .main_axis_alignment(MainAxisAlignment::Start)
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
}

fn nav_item(name: &str, route: Route, current: Route) -> impl WidgetView<App> + use<> {
    // No active-state button styling yet (needs masonry property plumbing); a
    // bullet marks the current page instead.
    let text = if route == current {
        format!("• {name}")
    } else {
        name.to_owned()
    };
    text_button(text, move |app: &mut App| {
        app.route = route;
    })
}

fn overview(app: &App) -> impl WidgetView<App> + use<> {
    let session: Box<AnyWidgetView<App>> = match &app.session {
        Session::SignedOut => flex_col((
            label("You can sign in from the taskbar icon, or with the button below.")
                .text_size(14.0),
            text_button("Sign in", |app: &mut App| {
                send(app, ControllerRequest::SignIn);
            }),
        ))
        .boxed(),
        Session::Loading => label("Signing in…").text_size(14.0).boxed(),
        Session::SignedIn {
            account_slug,
            actor_name,
        } => flex_col((
            label(format!("Signed in to {account_slug} as {actor_name}.")).text_size(14.0),
            text_button("Sign out", |app: &mut App| {
                send(app, ControllerRequest::SignOut);
            }),
        ))
        .boxed(),
    };

    flex_col((
        label("Firezone").text_size(40.0).weight(FontWeight::BOLD),
        session,
    ))
    .cross_axis_alignment(CrossAxisAlignment::Center)
    .main_axis_alignment(MainAxisAlignment::Center)
}

fn general_settings(app: &App) -> impl WidgetView<App> + use<> {
    let s = &app.general_settings;
    flex_col((
        label("Account slug").text_size(13.0),
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
            text_button("Save", |app: &mut App| {
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
        )),
    ))
    .cross_axis_alignment(CrossAxisAlignment::Start)
    .main_axis_alignment(MainAxisAlignment::Start)
}

fn advanced_settings(app: &App) -> impl WidgetView<App> + use<> {
    let s = &app.advanced_settings;
    flex_col((
        label(
            "WARNING: these settings are for internal debugging only. Changing \
             them is unsupported and will likely break the client.",
        )
        .text_size(13.0),
        label("Auth base URL").text_size(13.0),
        text_input(s.auth_url.clone(), |app: &mut App, v: String| {
            app.advanced_settings.auth_url = v;
        })
        .disabled(s.auth_url_is_managed),
        label("API URL").text_size(13.0),
        text_input(s.api_url.clone(), |app: &mut App, v: String| {
            app.advanced_settings.api_url = v;
        })
        .disabled(s.api_url_is_managed),
        label("Log filter").text_size(13.0),
        text_input(s.log_filter.clone(), |app: &mut App, v: String| {
            app.advanced_settings.log_filter = v;
        })
        .disabled(s.log_filter_is_managed),
        flex_row((
            text_button("Save", |app: &mut App| {
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
        )),
    ))
    .cross_axis_alignment(CrossAxisAlignment::Start)
    .main_axis_alignment(MainAxisAlignment::Start)
}

fn diagnostics(app: &App) -> impl WidgetView<App> + use<> {
    let count = &app.log_count;
    let megabytes = (count.bytes as f64) / 1_000_000.0;
    let summary = format!(
        "Log directory size: {} files, {megabytes:.1} MB",
        count.files
    );

    flex_col((
        label(summary).text_size(14.0),
        flex_row((
            text_button("Export Logs", |_app: &mut App| {
                // The iced path runs an async native file-save dialog
                // (Task::perform); a sync button callback can't block the
                // event loop on one, so this is left unwired for now.
                tracing::warn!("xilem: export logs not yet implemented");
            }),
            text_button("Clear Logs", |app: &mut App| {
                let (cb_tx, _cb_rx) = tokio::sync::oneshot::channel();
                send(app, ControllerRequest::ClearLogs(cb_tx));
            }),
        )),
    ))
    .cross_axis_alignment(CrossAxisAlignment::Center)
    .main_axis_alignment(MainAxisAlignment::Center)
}

fn about() -> impl WidgetView<App> + use<> {
    flex_col((
        label("Firezone").text_size(24.0).weight(FontWeight::BOLD),
        label(format!("Version {APP_VERSION}")).text_size(14.0),
        label(format!("({})", &GIT_SHA[..GIT_SHA.len().min(8)])).text_size(11.0),
        text_button("Documentation", |_app: &mut App| {
            let _ = open::that_detached("https://www.firezone.dev/kb");
        }),
    ))
    .cross_axis_alignment(CrossAxisAlignment::Center)
    .main_axis_alignment(MainAxisAlignment::Center)
}
