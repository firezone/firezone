import FirezoneKit
import Foundation

/// Commands that can be sent to the Session.
enum SessionCommand {
  case disconnect
  case setInternetResourceState(Bool)
  case setDns(String)
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
    // Event polling task - polls Rust for events and sends to eventSender
    group.addTask {
      while !Task.isCancelled {
        do {
          // Poll for next event from Rust
          if let event = try await session.nextEvent() {
            eventSender.send(event)
          } else {
            // No event returned - session has ended
            Log.log("SessionEventLoop: Event stream ended, exiting event loop")
            break
          }
        } catch {
          Log.error(error)
          Log.log("SessionEventLoop: Error in event polling, exiting event loop")
          break
        }
      }

      Log.log("SessionEventLoop: Event polling finished")
    }

    // Command handling task - receives commands from commandReceiver
    group.addTask {
      for await command in commandReceiver.stream {
        await handleCommand(command, session: session)

        // Exit loop if disconnect command
        if case .disconnect = command {
          Log.log("SessionEventLoop: Disconnect command received, exiting command loop")
          break
        }
      }

      Log.log("SessionEventLoop: Command handling finished")
    }

    // Wait for first task to complete, then cancel all
    _ = await group.next()
    Log.log("SessionEventLoop: One task completed, cancelling event loop")
    group.cancelAll()
  }
}

/// Handles a command by calling the appropriate session method.
private func handleCommand(_ command: SessionCommand, session: Session) async {
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
