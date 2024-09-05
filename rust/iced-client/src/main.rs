use iced::{
    event, executor,
    multi_window::Application,
    widget::{button, column, container, text},
    window, Alignment, Background, Border, Color, Command, Element, Event, Length, Renderer,
    Settings, Subscription,
};

pub fn main() -> iced::Result {
    let mut settings = Settings::default();
    settings.window.exit_on_close_request = false;
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
}

impl Application for FirezoneApp {
    type Executor = executor::Default;
    type Flags = ();
    type Message = Message;
    type Theme = FzTheme;

    fn new(_flags: ()) -> (Self, Command<Message>) {
        let (about_window, about_cmd) = window::spawn(Default::default());
        let (settings_window, settings_cmd) = window::spawn(Default::default());
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

    fn title(&self, window: window::Id) -> String {
        if window == self.about_window {
            "About Firezone"
        } else if window == self.settings_window {
            "Firezone Settings"
        } else if window == self.welcome_window {
            "Welcome to Firezone"
        } else {
            panic!("Impossible - Can't generate title for window we didn't make.")
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
        }
        Command::none()
    }

    fn view(&self, window: window::Id) -> Element<'_, Message, FzTheme, Renderer> {
        match window {
            _ => self.view_welcome(),
        }
    }
}

impl FirezoneApp {
    fn view_welcome(&self) -> Element<'_, Message, FzTheme, Renderer> {
        let content = column![
            button("Increment").on_press(Message::IncrementPressed),
            text(self.value).size(50),
            button("Decrement").on_press(Message::DecrementPressed)
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
