use tracing::Level;
use tracing_subscriber::layer::Filter;

/// Drops events at `level` whose message contains all of the given snippets.
///
/// The decision lives entirely in [`Filter::event_enabled`] because it needs the
/// event's fields, which [`Filter::enabled`] does not receive.
///
/// Never express this filter as its positive counterpart wrapped in
/// [`tracing_subscriber::filter::FilterExt::not`]. `Not` negates `enabled` and
/// returns `true` from `event_enabled` without delegating, so the message check
/// becomes unreachable and every event at `level` is dropped.
pub struct DropEventsWhoseMessageContains {
    level: Level,
    snippets: Vec<&'static str>,
}

impl DropEventsWhoseMessageContains {
    pub fn all(level: Level, snippets: &[&'static str]) -> Self {
        Self {
            level,
            snippets: snippets.to_vec(),
        }
    }
}

impl<S> Filter<S> for DropEventsWhoseMessageContains
where
    S: tracing::Subscriber,
{
    fn enabled(
        &self,
        _: &tracing::Metadata<'_>,
        _: &tracing_subscriber::layer::Context<'_, S>,
    ) -> bool {
        true
    }

    fn event_enabled(
        &self,
        event: &tracing::Event<'_>,
        _: &tracing_subscriber::layer::Context<'_, S>,
    ) -> bool {
        if event.metadata().level() != &self.level {
            return true;
        }

        let mut visitor = MessageVisitor { message: None };
        event.record(&mut visitor);

        let Some(message) = visitor.message else {
            return true;
        };

        !self
            .snippets
            .iter()
            .all(|snippet| message.contains(snippet))
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
    fn drops_events_matching_on_all_strings() {
        let capture = CapturingWriter::default();

        let _guard = tracing_subscriber::registry()
            .with(
                tracing_subscriber::fmt::layer()
                    .with_writer(capture.clone())
                    .with_filter(DropEventsWhoseMessageContains::all(
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
    fn keeps_events_at_the_filtered_level_whose_message_does_not_match() {
        let capture = CapturingWriter::default();

        let _guard = tracing_subscriber::registry()
            .with(
                tracing_subscriber::fmt::layer()
                    .with_writer(capture.clone())
                    .with_level(false)
                    .without_time()
                    .with_target(false)
                    .with_filter(DropEventsWhoseMessageContains::all(Level::ERROR, &["foo"])),
            )
            .set_default();

        tracing::error!("This is a message");

        assert_eq!(
            *capture.lines().lines().collect::<Vec<_>>(),
            vec!["This is a message".to_owned()]
        );
    }

    #[test]
    fn keeps_events_that_match_only_some_strings() {
        let capture = CapturingWriter::default();

        let _guard = tracing_subscriber::registry()
            .with(
                tracing_subscriber::fmt::layer()
                    .with_writer(capture.clone())
                    .with_level(false)
                    .without_time()
                    .with_target(false)
                    .with_filter(DropEventsWhoseMessageContains::all(
                        Level::DEBUG,
                        &["foo", "bar"],
                    )),
            )
            .set_default();

        tracing::debug!("This is a message containing foo");

        assert_eq!(
            *capture.lines().lines().collect::<Vec<_>>(),
            vec!["This is a message containing foo".to_owned()]
        );
    }

    #[test]
    fn keeps_events_at_other_levels() {
        let capture = CapturingWriter::default();

        let _guard = tracing_subscriber::registry()
            .with(
                tracing_subscriber::fmt::layer()
                    .with_writer(capture.clone())
                    .with_level(false)
                    .without_time()
                    .with_target(false)
                    .with_filter(DropEventsWhoseMessageContains::all(Level::DEBUG, &["foo"])),
            )
            .set_default();

        tracing::warn!("This is a message");

        assert_eq!(
            *capture.lines().lines().collect::<Vec<_>>(),
            vec!["This is a message".to_owned()]
        );
    }

    #[test]
    fn multiple_filters() {
        let capture = CapturingWriter::default();

        let _guard = tracing_subscriber::registry()
            .with(
                tracing_subscriber::fmt::layer()
                    .with_writer(capture.clone())
                    .with_level(false)
                    .without_time()
                    .with_target(false)
                    .with_filter(DropEventsWhoseMessageContains::all(Level::DEBUG, &["foo"]))
                    .with_filter(DropEventsWhoseMessageContains::all(Level::DEBUG, &["bar"]))
                    .with_filter(DropEventsWhoseMessageContains::all(Level::DEBUG, &["baz"])),
            )
            .set_default();

        tracing::debug!("foo");
        tracing::debug!("This is a message baz");
        tracing::debug!("bar");
        tracing::debug!("This is a message");
        tracing::warn!("This is a message");

        assert_eq!(
            *capture.lines().lines().collect::<Vec<_>>(),
            vec![
                "This is a message".to_owned(),
                "This is a message".to_owned()
            ]
        );
    }
}
