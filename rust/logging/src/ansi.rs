pub fn stdout_supports_ansi() -> bool {
    supports_color::on(supports_color::Stream::Stdout).is_some()
}
