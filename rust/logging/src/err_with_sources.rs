use core::fmt;
use std::error::Error;

/// Returns a [`fmt::Display`] adapter that prints the error and all its sources.
pub fn err_with_src<'a>(e: &'a (dyn Error + 'static)) -> ErrorWithSources<'a> {
    ErrorWithSources { e }
}

pub struct ErrorWithSources<'a> {
    e: &'a (dyn Error + 'static),
}

impl fmt::Display for ErrorWithSources<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.e)?;

        for cause in anyhow::Chain::new(self.e).skip(1) {
            write!(f, ": {cause}")?;
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prints_errors_with_sources() {
        let error = Error3(Error2(Error1));

        let display = err_with_src(&error);

        assert_eq!(display.to_string(), "Argh: Failed to do the thing: oh no!");
    }

    #[derive(thiserror::Error, Debug)]
    #[error("oh no!")]
    struct Error1;

    #[derive(thiserror::Error, Debug)]
    #[error("Failed to do the thing")]
    struct Error2(#[source] Error1);

    #[derive(thiserror::Error, Debug)]
    #[error("Argh")]
    struct Error3(#[source] Error2);
}
