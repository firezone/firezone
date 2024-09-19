use iced::{
    event,
    widget::{button, column, container, image, row, text, text_input},
    window, Alignment, Background, Border, Color, Event, Length, Renderer, Subscription,
};

type Element<'a> = iced::Element<'a, Message, FzTheme, Renderer>;

pub fn main() -> iced::Result {
    // The main icon should be at least 90x90, since Ubuntu's default
    // desktop wants 48 px, and that's nearly doubled if Ubuntu is
    // running in a HiDPI Parallels VM on a Mac.
    let icon = window::icon::from_file_data(
        include_bytes!("../../gui-client/src-tauri/icons/32x32.png"),
        None,
    )
    .expect("Baked-in icon PNG should always be decodable");

    /*
    let mut settings = Settings::with_flags(Flags { icon: icon.clone() });
    settings.window.exit_on_close_request = false;
    settings.window.icon = Some(icon);
    settings.window.size = [640, 480].into();
    */

    let logo = image::Handle::from_bytes(&include_bytes!("../../gui-client/src/logo.png")[..]);

    let settings = window::Settings {
        exit_on_close_request: false,
        icon: Some(icon),
        size: [640.0f32, 480.0].into(),
        ..Default::default()
    };

    let (about_window, about_task) = window::open(settings.clone());
    let (settings_window, settings_task) = window::open(settings.clone());
    let (welcome_window, welcome_task) = window::open(settings);

    let tasks = iced::Task::batch([about_task, settings_task, welcome_task]);

    let app_state = FirezoneApp {
        about_window,
        settings_window,
        welcome_window,

        logo,

        settings_tab: Default::default(),

        auth_base_url: String::new(),
        api_url: String::new(),
        log_filter: String::new(),
    };

    // What `iced` calls "daemon" here is a GUI app that doesn't
    // open any windows by default, has no "main" window, and continues
    // to run after all its windows are closed.
    let daemon = iced::daemon(FirezoneApp::title, FirezoneApp::update, FirezoneApp::view)
        .subscription(FirezoneApp::subscription);
    daemon.run_with(|| (app_state, tasks.map(|_| Message::WindowsAllOpen)))
}

struct FirezoneApp {
    about_window: window::Id,
    settings_window: window::Id,
    welcome_window: window::Id,

    logo: image::Handle,

    settings_tab: SettingsTab,

    auth_base_url: String,
    api_url: String,
    log_filter: String,
}

#[derive(Clone, Debug)]
enum SettingsTab {
    Advanced,
    DiagnosticLogs,
}

#[derive(Clone, Debug)]
enum SettingsField {
    AuthBaseUrl,
    ApiUrl,
    LogFilter,
}

impl Default for SettingsTab {
    fn default() -> Self {
        Self::Advanced
    }
}

#[derive(Clone, Debug)]
enum Message {
    ChangeSettingsTab(SettingsTab),
    CloseRequested(window::Id),
    InputChanged((SettingsField, String)),
    SignIn,
    Quit,
    WindowsAllOpen,
}

enum FzWindow {
    About,
    Settings,
    Welcome,
}

impl FirezoneApp {
    fn subscription(&self) -> Subscription<Message> {
        event::listen_with(|event, _status, id| match event {
            Event::Keyboard(_) => None,
            Event::Mouse(_) => None,
            Event::Touch(_) => None,
            Event::Window(iced::window::Event::CloseRequested) => Some(Message::CloseRequested(id)),
            Event::Window(_) => None,
        })
    }

    fn title(&self, id: window::Id) -> String {
        match self.fz_window(id) {
            FzWindow::About => "About Firezone",
            FzWindow::Settings => "Settings",
            FzWindow::Welcome => "Welcome to Firezone",
        }
        .into()
    }

    fn update(&mut self, message: Message) -> iced::Task<Message> {
        match message {
            Message::ChangeSettingsTab(new_tab) => self.settings_tab = new_tab,
            Message::InputChanged((field, s)) => match field {
                SettingsField::AuthBaseUrl => self.auth_base_url = s,
                SettingsField::ApiUrl => self.api_url = s,
                SettingsField::LogFilter => self.log_filter = s,
            },
            Message::CloseRequested(id) => {
                return window::change_mode::<Message>(id, window::Mode::Hidden)
            }
            Message::SignIn => {}
            // Closing all windows causes Iced to exit the app
            Message::Quit => {
                return iced::Task::batch([
                    window::close(self.about_window),
                    window::close(self.settings_window),
                    window::close(self.welcome_window),
                ])
            }
            Message::WindowsAllOpen => {}
        }
        iced::Task::none()
    }

    fn view(&self, id: window::Id) -> Element {
        match self.fz_window(id) {
            FzWindow::About => self.view_about(),
            FzWindow::Settings => self.view_settings(),
            FzWindow::Welcome => self.view_welcome(),
        }
    }

    fn view_about(&self) -> Element {
        let content = column![
            image::Image::new(self.logo.clone()).width(240).height(240),
            text("Version 42.9000"),
            button("Quit").on_press(Message::Quit).padding(16),
        ]
        .align_x(Alignment::Center);
        container(content)
            .center_x(Length::Fill)
            .center_y(Length::Fill)
            .into()
    }

    fn view_settings(&self) -> Element {
        let tabs = row![
            button("Advanced").on_press(Message::ChangeSettingsTab(SettingsTab::Advanced)),
            button("DiagnosticLogs")
                .on_press(Message::ChangeSettingsTab(SettingsTab::DiagnosticLogs)),
        ];
        let tabs = container(tabs).center_x(Length::Fill);

        let content = match self.settings_tab {
            SettingsTab::Advanced => self.tab_advanced_settings(),
            SettingsTab::DiagnosticLogs => self.tab_diagnostic_logs(),
        };

        let content = column!(tabs, content);

        container(content).height(Length::Fill).into()
    }

    fn tab_advanced_settings(&self) -> Element {
        let content = column![
            text("WARNING: These settings are intended for internal debug purposes only. Changing these is not supported and will disrupt access to your resources"),
            column![
                text_input("Auth Base URL", &self.auth_base_url).on_input(|s| Message::InputChanged((SettingsField::AuthBaseUrl, s))),
                text_input("API URL", &self.api_url).on_input(|s| Message::InputChanged((SettingsField::ApiUrl, s))),
                text_input("Log Filter", &self.log_filter).on_input(|s| Message::InputChanged((SettingsField::LogFilter, s))),
            ]
            .padding(20)
        ]
        .padding(20)
        .align_x(Alignment::Center);
        container(content)
            .center_x(Length::Fill)
            .center_y(Length::Fill)
            .into()
    }

    fn tab_diagnostic_logs(&self) -> Element {
        container(text("TODO"))
            .center_x(Length::Fill)
            .center_y(Length::Fill)
            .into()
    }

    fn view_welcome(&self) -> Element {
        let content = column![
            text("Welcome to Firezone.").size(32),
            text("Sign in below to get started."),
            image::Image::new(self.logo.clone()).width(200).height(200),
            button("Sign in").on_press(Message::SignIn).padding(16),
        ]
        .padding(20)
        .align_x(Alignment::Center);

        container(content)
            .center_x(Length::Fill)
            .center_y(Length::Fill)
            .into()
    }

    fn fz_window(&self, id: window::Id) -> FzWindow {
        if id == self.about_window {
            FzWindow::About
        } else if id == self.settings_window {
            FzWindow::Settings
        } else if id == self.welcome_window {
            FzWindow::Welcome
        } else {
            panic!("Impossible - Can't generate title for window we didn't make.")
        }
    }
}

#[derive(Clone, Default)]
struct FzTheme {}

impl iced::daemon::DefaultStyle for FzTheme {
    fn default_style(&self) -> iced::daemon::Appearance {
        iced::daemon::Appearance {
            background_color: Color::from_rgb8(0xf5, 0xf5, 0xf5),
            text_color: Color::from_rgb8(0x11, 0x18, 0x27),
        }
    }
}

impl button::Catalog for FzTheme {
    type Class<'a> = ();

    fn default<'a>() -> Self::Class<'a> {}

    fn style(&self, _: &Self::Class<'_>, status: button::Status) -> button::Style {
        match status {
            button::Status::Active | button::Status::Pressed => button::Style {
                background: Some(Background::Color(Color::from_rgb8(94, 0, 214))),
                border: Border {
                    color: Color::from_rgb8(0, 0, 0),
                    width: 0.0,
                    radius: 4.into(),
                },
                text_color: Color::from_rgb8(255, 255, 255),
                ..Default::default()
            },
            button::Status::Hovered => button::Style {
                background: Some(Background::Color(Color::from_rgb8(94, 0, 214))),
                border: Border {
                    color: Color::from_rgb8(0xf5, 0xf5, 0xf5),
                    width: 2.0,
                    radius: 4.into(),
                },
                text_color: Color::from_rgb8(255, 255, 255),
                ..Default::default()
            },
            button::Status::Disabled => button::Style {
                background: Some(Background::Color(Color::from_rgb8(96, 96, 96))),
                border: Border {
                    color: Color::from_rgb8(0, 0, 0),
                    width: 0.0,
                    radius: 4.into(),
                },
                text_color: Color::from_rgb8(0, 0, 0),
                ..Default::default()
            },
        }
    }
}

impl container::Catalog for FzTheme {
    type Class<'a> = ();

    fn default<'a>() -> Self::Class<'a> {}

    fn style(&self, _: &Self::Class<'_>) -> container::Style {
        Default::default()
    }
}

impl text::Catalog for FzTheme {
    type Class<'a> = ();

    fn default<'a>() -> Self::Class<'a> {}

    fn style(&self, _: &Self::Class<'_>) -> text::Style {
        Default::default()
    }
}

impl text_input::Catalog for FzTheme {
    type Class<'a> = ();

    fn default<'a>() -> Self::Class<'a> {}

    fn style(&self, _: &Self::Class<'_>, status: text_input::Status) -> text_input::Style {
        match status {
            text_input::Status::Active
            | text_input::Status::Disabled
            | text_input::Status::Focused
            | text_input::Status::Hovered => text_input::Style {
                background: Background::Color(Color::from_rgba8(0, 0, 0, 0.0)),
                border: Border {
                    color: Color::from_rgb8(0, 0, 0),
                    radius: 0.0.into(),
                    width: 0.0,
                },
                icon: Color::from_rgb8(0, 0, 0),
                placeholder: Color::from_rgb8(180, 180, 180),
                value: Color::from_rgb8(0, 0, 0),
                selection: Color::from_rgb8(0, 0, 255),
            },
        }
    }
}
