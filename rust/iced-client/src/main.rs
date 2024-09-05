use iced::{
    event, executor,
    multi_window::Application,
    widget::{button, column, container, text},
    window, Alignment, Background, Border, Color, Command, Event, Length, Renderer,
    Settings, Subscription,
};

type Element<'a> = iced::Element<'a, Message, FzTheme, Renderer>;

pub fn main() -> iced::Result {
    let mut settings = Settings::default();
    settings.window.exit_on_close_request = false;
    settings.window.size = [640, 480].into();
    FirezoneApp::run(settings)
}

struct FirezoneApp {
    about_window: window::Id,
    settings_window: window::Id,
    welcome_window: window::Id,
    value: i32,
}

#[derive(Debug, Clone)]
enum Message {
    IncrementPressed,
    DecrementPressed,
    SubscribedEvent(iced::Event),
    Quit,
}

enum FzWindow {
    About,
    Settings,
    Welcome,
}

impl Application for FirezoneApp {
    type Executor = executor::Default;
    type Flags = ();
    type Message = Message;
    type Theme = FzTheme;

    fn new(_flags: ()) -> (Self, Command<Message>) {
        let mut settings = window::Settings::default();
        settings.exit_on_close_request = false;
        settings.size = [640, 480].into();

        let (about_window, about_cmd) = window::spawn(settings.clone());
        let (settings_window, settings_cmd) = window::spawn(settings.clone());
        (
            Self {
                about_window,
                settings_window,
                welcome_window: window::Id::MAIN,

                value: 0,
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
            Message::IncrementPressed => {
                self.value += 1;
            }
            Message::DecrementPressed => {
                self.value -= 1;
            }
            Message::SubscribedEvent(Event::Window(id, window::Event::CloseRequested)) => {
                return window::change_mode::<Message>(id, window::Mode::Hidden)
            }
            Message::SubscribedEvent(_) => {}
            // Closing all windows causes Iced to exit the app
            Message::Quit => return Command::batch([
                window::close(self.about_window),
                window::close(self.settings_window),
                window::close(self.welcome_window),
            ]),
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
            text("Version 42.9000"),
            button("Quit").on_press(Message::Quit).padding(20),
        ];
        container(content)
            .width(Length::Fill)
            .height(Length::Fill)
            .center_x()
            .center_y()
            .into()
    }

    fn view_settings(&self) -> Element {
        let content = text("Settings");
        container(content)
            .width(Length::Fill)
            .height(Length::Fill)
            .center_x()
            .center_y()
            .into()
    }

    fn view_welcome(&self) -> Element {
        let content = column![
            button("Increment").on_press(Message::IncrementPressed),
            text(self.value).size(50),
            button("Decrement").on_press(Message::DecrementPressed),
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
            radius: 2.75.into(),
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
            radius: 2.75.into(),
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
            radius: 2.75.into(),
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
