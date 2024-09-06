use iced::{
    event, executor,
    multi_window::Application,
    widget::{button, column, container, image, row, text, text_input},
    window, Alignment, Background, Border, Color, Command, Event, Length, Renderer, Settings,
    Subscription,
};

type Element<'a> = iced::Element<'a, Message, FzTheme, Renderer>;

pub fn main() -> iced::Result {
    let icon = window::icon::from_file_data(
        include_bytes!("../../gui-client/src-tauri/icons/32x32.png"),
        None,
    )
    .expect("Baked-in icon PNG should always be decodable");

    let mut settings = Settings::with_flags(Flags { icon: icon.clone() });
    settings.window.exit_on_close_request = false;
    settings.window.icon = Some(icon);
    settings.window.size = [640, 480].into();

    FirezoneApp::run(settings)
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
    InputChanged((SettingsField, String)),
    SignIn,
    SubscribedEvent(iced::Event),
    Quit,
}

enum FzWindow {
    About,
    Settings,
    Welcome,
}

struct Flags {
    icon: window::Icon,
}

impl Default for Flags {
    fn default() -> Self {
        unreachable!()
    }
}

impl Application for FirezoneApp {
    type Executor = executor::Default;
    type Flags = Flags;
    type Message = Message;
    type Theme = FzTheme;

    // I don't know why `iced` calls these params `flags`.
    fn new(flags: Self::Flags) -> (Self, Command<Message>) {
        let logo = image::Handle::from_memory(include_bytes!("../../gui-client/src/logo.png"));

        let mut settings = window::Settings::default();
        settings.exit_on_close_request = false;
        settings.icon = Some(flags.icon.clone());
        settings.size = [640, 480].into();

        let (about_window, about_cmd) = window::spawn(settings.clone());
        let (settings_window, settings_cmd) = window::spawn(settings.clone());

        (
            Self {
                about_window,
                settings_window,
                welcome_window: window::Id::MAIN,

                logo,

                settings_tab: Default::default(),

                auth_base_url: String::new(),
                api_url: String::new(),
                log_filter: String::new(),
            },
            Command::batch([about_cmd, settings_cmd]),
        )
    }

    fn subscription(&self) -> Subscription<Self::Message> {
        event::listen().map(Message::SubscribedEvent)
    }

    fn theme(&self, _window: window::Id) -> Self::Theme {
        Default::default()
    }

    fn title(&self, id: window::Id) -> String {
        match self.fz_window(id) {
            FzWindow::About => "About Firezone",
            FzWindow::Settings => "Settings",
            FzWindow::Welcome => "Welcome to Firezone",
        }
        .into()
    }

    fn update(&mut self, message: Message) -> Command<Message> {
        match message {
            Message::ChangeSettingsTab(new_tab) => self.settings_tab = new_tab,
            Message::InputChanged((field, s)) => match field {
                SettingsField::AuthBaseUrl => self.auth_base_url = s,
                SettingsField::ApiUrl => self.api_url = s,
                SettingsField::LogFilter => self.log_filter = s,
            },
            Message::SubscribedEvent(Event::Window(id, window::Event::CloseRequested)) => {
                return window::change_mode::<Message>(id, window::Mode::Hidden)
            }
            Message::SignIn | Message::SubscribedEvent(_) => {}
            // Closing all windows causes Iced to exit the app
            Message::Quit => {
                return Command::batch([
                    window::close(self.about_window),
                    window::close(self.settings_window),
                    window::close(self.welcome_window),
                ])
            }
        }
        Command::none()
    }

    fn view(&self, id: window::Id) -> Element {
        match self.fz_window(id) {
            FzWindow::About => self.view_about(),
            FzWindow::Settings => self.view_settings(),
            FzWindow::Welcome => self.view_welcome(),
        }
    }
}

impl FirezoneApp {
    fn view_about(&self) -> Element {
        let content = column![
            image::Image::new(self.logo.clone()).width(240).height(240),
            text("Version 42.9000"),
            button("Quit").on_press(Message::Quit).padding(16),
        ]
        .align_items(Alignment::Center);
        container(content)
            .width(Length::Fill)
            .height(Length::Fill)
            .center_x()
            .center_y()
            .into()
    }

    fn view_settings(&self) -> Element {
        let tabs = row![
            button("Advanced").on_press(Message::ChangeSettingsTab(SettingsTab::Advanced)),
            button("DiagnosticLogs")
                .on_press(Message::ChangeSettingsTab(SettingsTab::DiagnosticLogs)),
        ];
        let tabs = container(tabs).width(Length::Fill).center_x();

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
        .align_items(Alignment::Center);
        container(content)
            .width(Length::Fill)
            .height(Length::Fill)
            .center_x()
            .center_y()
            .into()
    }

    fn tab_diagnostic_logs(&self) -> Element {
        container(text("TODO"))
            .width(Length::Fill)
            .height(Length::Fill)
            .center_x()
            .center_y()
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
        .align_items(Alignment::Center);

        container(content)
            .width(Length::Fill)
            .height(Length::Fill)
            .center_x()
            .center_y()
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

impl iced::application::StyleSheet for FzTheme {
    type Style = ();

    fn appearance(&self, _style: &Self::Style) -> iced::application::Appearance {
        iced::application::Appearance {
            background_color: Color::from_rgb8(0xf5, 0xf5, 0xf5),
            text_color: Color::from_rgb8(0x11, 0x18, 0x27),
        }
    }
}

impl button::StyleSheet for FzTheme {
    type Style = ();

    fn active(&self, _style: &Self::Style) -> button::Appearance {
        let mut x = button::Appearance::default();
        x.background = Some(Background::Color(Color::from_rgb8(94, 0, 214)));
        x.border = Border {
            color: Color::from_rgb8(0, 0, 0),
            width: 0.0,
            radius: 4.into(),
        };
        x.text_color = Color::from_rgb8(255, 255, 255);
        x
    }

    fn hovered(&self, _style: &Self::Style) -> button::Appearance {
        let mut x = button::Appearance::default();
        x.background = Some(Background::Color(Color::from_rgb8(94, 0, 214)));
        x.border = Border {
            color: Color::from_rgb8(0xf5, 0xf5, 0xf5),
            width: 2.0,
            radius: 4.into(),
        };
        x.text_color = Color::from_rgb8(255, 255, 255);
        x
    }

    fn pressed(&self, style: &Self::Style) -> button::Appearance {
        button::StyleSheet::active(self, style)
    }

    fn disabled(&self, _style: &Self::Style) -> button::Appearance {
        let mut x = button::Appearance::default();
        x.background = Some(Background::Color(Color::from_rgb8(96, 96, 96)));
        x.border = Border {
            color: Color::from_rgb8(0, 0, 0),
            width: 0.0,
            radius: 4.into(),
        };
        x.text_color = Color::from_rgb8(0, 0, 0);
        x
    }
}

impl container::StyleSheet for FzTheme {
    type Style = ();

    fn appearance(&self, _style: &Self::Style) -> container::Appearance {
        Default::default()
    }
}

impl text::StyleSheet for FzTheme {
    type Style = ();

    fn appearance(&self, _style: Self::Style) -> text::Appearance {
        Default::default()
    }
}

impl text_input::StyleSheet for FzTheme {
    type Style = ();

    fn active(&self, _style: &Self::Style) -> text_input::Appearance {
        text_input::Appearance {
            background: Background::Color(Color::from_rgba8(0, 0, 0, 0.0)),
            border: Border {
                color: Color::from_rgb8(0, 0, 0),
                radius: 0.0.into(),
                width: 0.0,
            },
            icon_color: Color::from_rgb8(0, 0, 0),
        }
    }

    fn focused(&self, style: &Self::Style) -> text_input::Appearance {
        text_input::StyleSheet::active(self, style)
    }

    fn placeholder_color(&self, _style: &Self::Style) -> Color {
        Color::from_rgb8(180, 180, 180)
    }

    fn value_color(&self, _style: &Self::Style) -> Color {
        Color::from_rgb8(0, 0, 0)
    }

    fn disabled_color(&self, _style: &Self::Style) -> Color {
        todo!()
    }

    fn selection_color(&self, _style: &Self::Style) -> Color {
        Color::from_rgb8(0, 0, 255)
    }

    fn disabled(&self, style: &Self::Style) -> text_input::Appearance {
        text_input::StyleSheet::active(self, style)
    }
}
