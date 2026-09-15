import FirezoneKit
import Foundation

/// Pumps events out of the session, owning its lifecycle.
///
/// Commands travel the other way by calling the session directly, which is safe
/// from any thread and does not block: connlib already queues them against the
/// runtime it owns. This loop ends when connlib closes the event stream, which
/// is what drops the session on the Rust side.
func runSessionEventLoop(
  session: Session,
  eventSender: Sender<Event>
) async {
  while !Task.isCancelled {
    guard let event = await session.nextEvent() else {
      Log.log("Event stream ended")
      break
    }

    eventSender.send(event)
  }
}
