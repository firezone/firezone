//! The window of the GUI client, drawn with Freya.

use std::time::Duration;

use freya::prelude::*;
use tokio::sync::mpsc;

use crate::{
    controller::ControllerRequest,
    logging::FileCount,
    settings::{GeneralSettingsViewModel, LogFilterViewModel},
    view::{ClientSettingsForm, SessionViewModel, X509Certificate},
};

mod components;
mod pages;
mod theme;

#[cfg(test)]
mod tests;

use components::{Icon, icon, icon_button, pal, text};

pub(crate) const SANS: &str = "Roboto";
const MONO: &str = "Roboto Mono";
pub(crate) const FONTS: [(&str, &[u8]); 5] = [
    (SANS, include_bytes!("../assets/roboto-400.ttf")),
    (SANS, include_bytes!("../assets/roboto-500.ttf")),
    (SANS, include_bytes!("../assets/roboto-600.ttf")),
    (SANS, include_bytes!("../assets/roboto-700.ttf")),
    (MONO, include_bytes!("../assets/roboto-mono-400.ttf")),
];

pub(crate) const WINDOW_SIZE: (f64, f64) = (900., 500.);

/// What the Controller last told the GUI. `None` is what it has not sent yet.
#[derive(Clone, Default)]
pub(crate) struct ViewModel {
    pub(crate) session: Option<SessionViewModel>,
    pub(crate) general_settings: Option<GeneralSettingsViewModel>,
    pub(crate) log_filter: Option<LogFilterViewModel>,
    pub(crate) log_count: Option<FileCount>,
    pub(crate) certificate: Option<X509Certificate>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Page {
    Overview,
    Settings,
    DeviceTrust,
    Diagnostics,
    About,
    ColorPalette,
}

/// The state the window renders, shared with the Controller through [`crate::gui`].
///
/// It outlives the window, so a window that opens again shows the last state right away.
#[derive(Clone)]
pub(crate) struct Ui {
    pub(crate) view_model: State<ViewModel>,
    pub(crate) page: State<Page>,
    pub(crate) requests: Requests,
    pub(crate) build: Build,
}

/// What the About page says the client was built from.
#[derive(Clone, Copy)]
pub(crate) struct Build {
    pub(crate) version: &'static str,
    pub(crate) git_sha: &'static str,
}

impl Ui {
    /// Creates the state on the GUI thread, before the event loop starts.
    pub(crate) fn new(requests: Requests, build: Build) -> Self {
        Self {
            view_model: State::create_global(ViewModel::default()),
            page: State::create_global(Page::Overview),
            requests,
            build,
        }
    }

    fn get() -> Self {
        GlobalContexts::get().get_context::<Self>()
    }
}

/// Sends what the user asks for to the Controller.
#[derive(Clone)]
pub(crate) struct Requests {
    pub(crate) tx: mpsc::Sender<ControllerRequest>,
    /// Runs the requests, because the GUI thread has no Tokio runtime.
    pub(crate) rt: tokio::runtime::Handle,
    pub(crate) inject_faults: bool,
}

impl Requests {
    fn send(&self, request: ControllerRequest) {
        let tx = self.tx.clone();

        self.rt.spawn(async move {
            let name = request.to_string();
            if tx.send(request).await.is_err() {
                tracing::warn!(%name, "The Controller is gone");
            }
        });
    }

    fn sign_in(&self) {
        self.send(ControllerRequest::SignIn);
    }

    fn sign_out(&self) {
        self.send(ControllerRequest::SignOut);
    }

    fn update_state(&self) {
        self.send(ControllerRequest::UpdateState);
    }

    fn reset_client_settings(&self) {
        self.send(ControllerRequest::ResetClientSettings);
    }

    fn apply_client_settings(&self, form: ClientSettingsForm) {
        let this = self.clone();

        self.rt.spawn(async move {
            this.inject_fault().await;
            this.send(ControllerRequest::ApplyClientSettings(Box::new(form)));
        });
    }

    /// Returns why the log filter is rejected, or [`None`] once it was sent.
    fn apply_log_filter(&self, log_filter: String) -> Option<String> {
        if let Err(e) = crate::view::check_log_filter(&log_filter) {
            return Some(e);
        }

        let this = self.clone();
        self.rt.spawn(async move {
            this.inject_fault().await;
            this.send(ControllerRequest::ApplyLogFilter(log_filter));
        });

        None
    }

    fn clear_logs(&self) {
        let tx = self.tx.clone();

        self.rt.spawn(async move {
            let (result_tx, result_rx) = tokio::sync::oneshot::channel();
            if tx
                .send(ControllerRequest::ClearLogs(result_tx))
                .await
                .is_err()
            {
                return;
            }

            match result_rx.await {
                Ok(Ok(())) => {}
                Ok(Err(e)) => tracing::warn!("Failed to clear logs: {e}"),
                Err(_) => tracing::debug!("The Controller dropped the `ClearLogs` request"),
            }
        });
    }

    fn export_logs(&self) {
        let tx = self.tx.clone();

        self.rt.spawn(async move {
            let Some(request) = crate::view::pick_log_export().await else {
                return;
            };

            let _ = tx.send(request).await;
        });
    }

    async fn inject_fault(&self) {
        if self.inject_faults {
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }
}

/// The root of the window.
pub(crate) fn app() -> impl IntoElement {
    let ui = Ui::get();
    use_hook(|| ui.requests.update_state());

    let p = pal();
    let view_model = ui.view_model.read().clone();
    let current = match *ui.page.read() {
        Page::Overview => Page::Overview,
        Page::Settings => Page::Settings,
        Page::DeviceTrust if view_model.certificate.is_none() => Page::Overview,
        Page::DeviceTrust => Page::DeviceTrust,
        Page::Diagnostics => Page::Diagnostics,
        Page::About => Page::About,
        Page::ColorPalette if !cfg!(debug_assertions) => Page::Overview,
        Page::ColorPalette => Page::ColorPalette,
    };
    let title = match current {
        Page::Overview => "Firezone",
        Page::Settings => "Settings",
        Page::DeviceTrust => "Device Trust",
        Page::Diagnostics => "Diagnostics",
        Page::About => "About",
        Page::ColorPalette => "Colour Palette",
    };
    let content = match current {
        Page::Overview => pages::Overview(view_model.session).into_element(),
        Page::Settings => pages::GeneralSettings(view_model.general_settings).into_element(),
        Page::DeviceTrust => pages::device_trust(view_model.certificate.as_ref()).into_element(),
        Page::Diagnostics => pages::Diagnostics {
            log_count: view_model.log_count,
            log_filter: view_model.log_filter,
        }
        .into_element(),
        Page::About => pages::about(ui.build).into_element(),
        Page::ColorPalette => pages::color_palette().into_element(),
    };

    // A 1px frame of `border_strong` around the rounded window.
    rect()
        .expanded()
        .corner_radius(8.)
        .background(p.border_strong)
        .padding(1.)
        .child(
            rect()
                .expanded()
                .corner_radius(7.)
                .overflow(Overflow::Clip)
                .background(p.surface)
                .color(p.body)
                .font_family(SANS)
                .font_size(14.)
                .text_height(TextHeightBehavior::All)
                .child(titlebar(title))
                .child(
                    rect()
                        .width(Size::fill())
                        .height(Size::flex(1.))
                        .content(Content::Flex)
                        .horizontal()
                        .child(components::sidebar(
                            ui.page,
                            current,
                            view_model.certificate.is_some(),
                        ))
                        .child(
                            rect()
                                .width(Size::flex(1.))
                                .height(Size::fill())
                                .background(p.canvas)
                                .child(content),
                        ),
                ),
        )
}

fn titlebar(title: &'static str) -> impl IntoElement {
    let p = pal();

    rect()
        .width(Size::fill())
        .height(Size::px(56.))
        .padding((0., 12., 0., 16.))
        .horizontal()
        .main_align(Alignment::SpaceBetween)
        .cross_align(Alignment::Center)
        .background(p.surface)
        .border(components::border_bottom(p.border))
        .window_drag()
        .child(
            text(title, 14.)
                .font_weight(FontWeight::SEMI_BOLD)
                .color(p.heading),
        )
        .child(
            icon_button(icon(Icon::Close, 16., p.body), "Close window")
                .on_press(|_| Platform::get().close_window(Platform::window_id())),
        )
}
