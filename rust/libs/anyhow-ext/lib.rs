pub use anyhow::*;

pub trait ErrorExt {
    fn any_is<T>(&self) -> bool
    where
        T: std::error::Error + Send + Sync + 'static;
    fn any_downcast_ref<T>(&self) -> Option<&T>
    where
        T: std::error::Error + Send + Sync + 'static;
}

impl ErrorExt for anyhow::Error {
    fn any_is<T>(&self) -> bool
    where
        T: std::error::Error + Send + Sync + 'static,
    {
        self.any_downcast_ref::<T>().is_some()
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "We are implementing the alternative."
    )]
    fn any_downcast_ref<T>(&self) -> Option<&T>
    where
        T: std::error::Error + Send + Sync + 'static,
    {
        std::iter::empty()
            .chain(self.downcast_ref::<T>())
            .chain(self.chain().flat_map(|e| e.downcast_ref::<T>()))
            .chain(
                self.chain()
                    .filter_map(custom_io_error)
                    .flat_map(|e| e.downcast_ref::<T>()),
            )
            .next()
    }
}

/// Returns the custom error `error` carries, if it is an [`std::io::Error`] built from one.
///
/// [`std::error::Error::source`] on an [`std::io::Error`] reports the source of its custom
/// error rather than that error itself, so walking sources alone never observes it.
fn custom_io_error<'a>(
    error: &'a (dyn std::error::Error + 'static),
) -> Option<&'a (dyn std::error::Error + Send + Sync + 'static)> {
    error.downcast_ref::<std::io::Error>()?.get_ref()
}

#[cfg(test)]
mod tests {
    use std::io;

    use anyhow::{Context, Result};

    use super::*;

    #[test]
    fn any_is_works_for_context() {
        let error = Result::<(), _>::Err(io::Error::other("Test"))
            .context("Foobar")
            .unwrap_err();

        assert!(error.any_is::<io::Error>())
    }

    #[test]
    fn any_is_works_for_typed_context() {
        let error = Result::<(), _>::Err(io::Error::other("Test"))
            .context(FooError)
            .unwrap_err();

        assert!(error.any_is::<FooError>())
    }

    #[test]
    fn any_is_works_for_anyhow_new() {
        let error = Result::<(), _>::Err(anyhow::Error::new(io::Error::other("Test")))
            .context("Foobar")
            .unwrap_err();

        assert!(error.any_is::<io::Error>())
    }

    #[test]
    fn any_is_works_for_custom_error_with_source() {
        let error = Result::<(), _>::Err(BazError(BarError(FooError)))
            .context("Foobar")
            .unwrap_err();

        assert!(error.any_is::<BazError>());
        assert!(error.any_is::<BarError>());
        assert!(error.any_is::<FooError>());
    }

    #[test]
    fn any_is_works_for_custom_error_inside_io_error() {
        let error = Result::<(), _>::Err(io::Error::other(FooError))
            .context("Foobar")
            .unwrap_err();

        assert!(error.any_is::<FooError>())
    }

    #[test]
    fn any_downcast_ref_works_for_context() {
        let error = Result::<(), _>::Err(io::Error::other("Test"))
            .context("Foobar")
            .unwrap_err();

        assert_eq!(
            error.any_downcast_ref::<io::Error>().unwrap().to_string(),
            "Test"
        )
    }

    #[test]
    fn any_downcast_ref_works_for_typed() {
        let error = Result::<(), _>::Err(io::Error::other("Test"))
            .context(FooError)
            .unwrap_err();

        assert_eq!(
            error.any_downcast_ref::<FooError>().unwrap().to_string(),
            "Foo"
        )
    }

    #[test]
    fn any_downcast_ref_works_for_anyhow_new() {
        let error = Result::<(), _>::Err(anyhow::Error::new(io::Error::other("Test")))
            .context("Foobar")
            .unwrap_err();

        assert_eq!(
            error.any_downcast_ref::<io::Error>().unwrap().to_string(),
            "Test"
        )
    }

    #[test]
    fn any_downcast_ref_works_for_custom_error_with_source() {
        let error = Result::<(), _>::Err(BazError(BarError(FooError)))
            .context("Foobar")
            .unwrap_err();

        assert_eq!(
            error.any_downcast_ref::<BazError>().unwrap().to_string(),
            "Baz"
        );
        assert_eq!(
            error.any_downcast_ref::<BarError>().unwrap().to_string(),
            "Bar"
        );
        assert_eq!(
            error.any_downcast_ref::<FooError>().unwrap().to_string(),
            "Foo"
        );
    }

    #[derive(Debug, thiserror::Error)]
    #[error("Foo")]
    struct FooError;

    #[derive(Debug, thiserror::Error)]
    #[error("Bar")]
    struct BarError(#[from] FooError);

    #[derive(Debug, thiserror::Error)]
    #[error("Baz")]
    struct BazError(#[from] BarError);
}
