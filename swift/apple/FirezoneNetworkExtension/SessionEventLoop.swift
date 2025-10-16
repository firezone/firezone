import FirezoneKit
import Foundation

/// Commands that can be sent to the Session.
enum SessionCommand {
  case disconnect
  case setInternetResourceState(Bool)
  case setDns([String])
  case reset(String)
}

/// Runs the session event loop, owning the Session lifecycle.
///
/// When either task completes, both are cancelled and the function returns.
/// This ensures the Session's Drop is called on the Rust side.
func runSessionEventLoop(
  session: Session,
  commandReceiver: Receiver<SessionCommand>,
  eventSender: Sender<Event>
) async {

  // Multiplex between commands and events
  await withTaskGroup(of: Void.self) { group in
    group.addTask {
      await forwardEvents(from: session, to: eventSender)
    }

    group.addTask {
      await forwardCommands(from: commandReceiver, to: session)
    }

    // Wait for first task to complete, then cancel all
    _ = await group.next()
    group.cancelAll()
  }
}

/// Forwards events from the session to the event sender.
private func forwardEvents(from session: Session, to eventSender: Sender<Event>) async {
  while !Task.isCancelled {
    guard let event = await session.nextEvent() else {
      Log.log("Event stream ended")
      break
    }

    eventSender.send(event)
  }
}

/// Forwards commands from the command receiver to the session.
private func forwardCommands(from commandReceiver: Receiver<SessionCommand>, to session: Session) async {
  for await command in commandReceiver.stream {
    if Task.isCancelled {
      Log.log("Command forwarding cancelled")
      break
    }

    do {
      switch command {
      case .disconnect:
        try session.disconnect()

      case .setInternetResourceState(let active):
        session.setInternetResourceState(active: active)

      case .setDns(let servers):
        try session.setDns(dnsServers: servers)

      case .reset(let reason):
        session.reset(reason: reason)
      }
    } catch {
      Log.error("Failed to forward command to session: \(error)")
    }
  }

  Log.log("Command stream ended")
}
