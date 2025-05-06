use tracing::Level;
use tracing_subscriber::layer::Filter;

/// Filters out all events whose message contains all of the given snippets.
pub struct EventMessageContains {
    level: Level,
    snippets: Vec<&'static str>,
}

impl EventMessageContains {
    pub fn all(level: Level, snippets: &[&'static str]) -> Self {
        Self {
            level,
            snippets: snippets.to_vec(),
        }
    }
}

impl<S> Filter<S> for EventMessageContains
where
    S: tracing::Subscriber,
{
    fn enabled(
        &self,
        metadata: &tracing::Metadata<'_>,
        _: &tracing_subscriber::layer::Context<'_, S>,
    ) -> bool {
        if metadata.level() != &self.level {
            return false;
        }

        true
    }

    fn event_enabled(
        &self,
        event: &tracing::Event<'_>,
        _: &tracing_subscriber::layer::Context<'_, S>,
    ) -> bool {
        let mut visitor = MessageVisitor { message: None };
        event.record(&mut visitor);

        let Some(message) = visitor.message else {
            return true;
        };

        if self
            .snippets
            .iter()
            .all(|snippet| message.contains(snippet))
        {
            return false;
        }

        true
    }
}

struct MessageVisitor {
    message: Option<String>,
}

impl tracing::field::Visit for MessageVisitor {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if self.message.is_some() {
            return;
        }

        if field.name() != "message" {
            return;
        }

        self.message = Some(format!("{value:?}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::capturing_writer::CapturingWriter;
    use tracing_subscriber::{Layer, layer::SubscriberExt, util::SubscriberInitExt};

    #[test]
    fn matches_on_all_strings() {
        let capture = CapturingWriter::default();

        let _guard = tracing_subscriber::registry()
            .with(
                tracing_subscriber::fmt::layer()
                    .with_writer(capture.clone())
                    .with_filter(EventMessageContains::all(
                        Level::DEBUG,
                        &["foo", r#"bar ("xyz")"#, "baz"],
                    )),
            )
            .set_default();

        tracing::debug!(
            r#"This is a message containing foo: The error was caused by bar ("xyz") and baz"#
        );

        assert!(capture.lines().is_empty());
    }

    #[test]
    fn passes_through_non_matching_events() {
        let capture = CapturingWriter::default();

        let _guard = tracing_subscriber::registry()
            .with(
                tracing_subscriber::fmt::layer()
                    .with_writer(capture.clone())
                    .with_level(false)
                    .without_time()
                    .with_target(false)
                    .with_filter(EventMessageContains::all(Level::DEBUG, &["foo"])),
            )
            .set_default();

        tracing::debug!("This is a message");

        assert_eq!(
            *capture.lines().lines().collect::<Vec<_>>(),
            vec!["This is a message".to_owned()]
        );
    }
}
