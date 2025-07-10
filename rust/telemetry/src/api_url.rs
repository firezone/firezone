#[derive(Debug, PartialEq)]
pub(crate) struct ApiUrl<'a>(&'a str);

impl ApiUrl<'static> {
    pub(crate) const PROD: Self = ApiUrl("wss://api.firezone.dev");
    pub(crate) const STAGING: Self = ApiUrl("wss://api.firez.one");
    pub(crate) const DOCKER_COMPOSE: Self = ApiUrl("ws://api:8081");
    pub(crate) const LOCALHOST: Self = ApiUrl("ws://localhost:8081");
}

impl<'a> ApiUrl<'a> {
    pub(crate) fn new(url: &'a str) -> Self {
        Self(url.trim_end_matches("/"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trailing_slash_is_trimmed() {
        assert_eq!(ApiUrl::new("wss://api.firezone.dev/"), ApiUrl::PROD)
    }
}
