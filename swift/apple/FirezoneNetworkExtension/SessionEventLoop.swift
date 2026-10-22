import FirezoneKit
import Foundation

/// Commands that can be sent to the Session.
enum SessionCommand {
  case disconnect
  case setInternetResourceState(Bool)
  case setDns([String])
  case reset(String)
}

/// Hands a session to exactly one owner.
actor SessionHandoff {
  private var session: Session?

  init(_ session: Session) {
    self.session = session
  }

  func take() -> Session? {
    defer { session = nil }
    return session
  }
}

/// Runs the session event loop until the command stream ends.
///
/// The command task is the session's only owner, and dropping the session ends the event stream.
func runSessionEventLoop(
  handoff: SessionHandoff,
  events: EventStream,
  commandReceiver: Receiver<SessionCommand>,
  eventSender: Sender<Event>
) async {

  // Multiplex between commands and events
  await withTaskGroup(of: Void.self) { group in
    group.addTask {
      await forwardEvents(from: events, to: eventSender)
    }

    group.addTask {
      guard let session = await handoff.take() else { return }

      await forwardCommands(from: commandReceiver, to: session)
    }

    // Wait for first task to complete, then cancel all
    _ = await group.next()
    group.cancelAll()
  }
}

/// Forwards events from the event stream to the event sender.
///
/// Swift cannot cancel a pending `EventStream.next()`, so this must not hold the session.
private func forwardEvents(from events: EventStream, to eventSender: Sender<Event>) async {
  while !Task.isCancelled {
    guard let event = await events.next() else {
      Log.log("Event stream ended")
      break
    }

    eventSender.send(event)
  }
}

/// Forwards commands from the command receiver to the session.
private func forwardCommands(from commandReceiver: Receiver<SessionCommand>, to session: Session)
  async
{
  for await command in commandReceiver.stream {
    if Task.isCancelled {
      Log.log("Command forwarding cancelled")
      break
    }

    // Logged before the call: a command that never arrives differs from one that never returns.
    Log.log("Forwarding \(command) to session")

    switch command {
    case .disconnect:
      session.disconnect()

    case .setInternetResourceState(let active):
      session.setInternetResourceState(active: active)

    case .setDns(let servers):
      session.setDns(dnsServers: servers)

    case .reset(let reason):
      session.reset(reason: reason)
    }
  }

  Log.log("Command stream ended")
}
