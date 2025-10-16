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
      while !Task.isCancelled {
        guard let event = await session.nextEvent() else {
          Log.log("Event stream ended")
          break
        }

        eventSender.send(event)
      }
    }

    group.addTask {
      for await command in commandReceiver.stream {
        handleCommand(command, session: session)
      }

      Log.log("Command stream ended")
    }

    // Wait for first task to complete, then cancel all
    _ = await group.next()
    group.cancelAll()
  }
}

/// Handles a command by calling the appropriate session method.
private func handleCommand(_ command: SessionCommand, session: Session) {
  switch command {
  case .disconnect:
    do {
      try session.disconnect()
    } catch {
      Log.error(error)
    }

  case .setInternetResourceState(let active):
    session.setInternetResourceState(active: active)

  case .setDns(let servers):
    do {
      try session.setDns(dnsServers: servers)
    } catch {
      Log.error(error)
    }

  case .reset(let reason):
    session.reset(reason: reason)
  }
}
