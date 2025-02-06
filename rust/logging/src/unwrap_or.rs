#[macro_export]
macro_rules! unwrap_or_warn {
    (
        $result:expr,
        $($arg:tt)*
    ) => {
        match $result {
            Ok(()) => {}
            Err(e) => {
                let error: &dyn ::std::error::Error = e.as_ref();

                ::tracing::debug!($($arg)*, $crate::err_with_src(error))
            }
        }
    };
}

#[macro_export]
macro_rules! unwrap_or_debug {
    (
        $result:expr,
        $($arg:tt)*
    ) => {
        match $result {
            Ok(()) => {}
            Err(e) => {
                let error: &dyn ::std::error::Error = e.as_ref();

                ::tracing::debug!($($arg)*, $crate::err_with_src(error))
            }
        }
    };
}

#[macro_export]
macro_rules! unwrap_or_trace {
    (
        $result:expr,
        $($arg:tt)*
    ) => {
        match $result {
            Ok(()) => {}
            Err(e) => {
                let error: &dyn ::std::error::Error = e.as_ref();

                ::tracing::debug!($($arg)*, $crate::err_with_src(error))
            }
        }
    };
}
