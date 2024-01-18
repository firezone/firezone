//! Inter-process communication for the connlib subprocess

#[cfg(test)]
mod tests {
    use ipc_channel::ipc;
    use serde::{Deserialize, Serialize};
    use std::time::Duration;
    use tokio::runtime::Runtime;

    #[derive(Debug, Deserialize, PartialEq, Serialize)]
    enum Message {
        AwaitCallback,
        Callback,
        Connect,
        Connected,
        Disconnect,
        Disconnected,
    }

    #[test]
    fn ipc() -> anyhow::Result<()> {
        let rt = Runtime::new()?;
        rt.block_on(async move {
            let timeout = Duration::from_millis(3000);

            // Pretend we're in the main process
            let (server, server_name) =
                ipc::IpcOneShotServer::<ipc::IpcSender<(Message, ipc::IpcSender<Message>)>>::new()
                    .unwrap();

            // `spawn_blocking` because this would probably deadlock if both tasks ran
            // on a single executor thread
            let worker_task = tokio::task::spawn_blocking(move || {
                // Pretend we're in a worker process
                let (tx, rx) = ipc::channel::<(Message, ipc::IpcSender<Message>)>().unwrap();
                ipc::IpcSender::connect(server_name)
                    .unwrap()
                    .send(tx)
                    .unwrap();

                // Handle requests from the main process
                loop {
                    let (req, response_tx) = rx.try_recv_timeout(timeout).unwrap();
                    match req {
                        Message::AwaitCallback => {
                            std::thread::sleep(Duration::from_secs(2));
                            response_tx.send(Message::Callback).unwrap();
                        }
                        Message::Connect => response_tx.send(Message::Connected).unwrap(),
                        Message::Disconnect => {
                            response_tx.send(Message::Disconnected).unwrap();
                            break;
                        }
                        _ => panic!("protocol error"),
                    }
                }
            });

            let (_, tx) = server.accept().unwrap();

            let start_time = std::time::Instant::now();

            // Pretend we're making some requests to the worker process

            // This is very wasteful - Every request creates a new IPC client-server
            // pair. It's possible to do it more efficiently than this, but the code is simple
            // and it allows `Message` to impl `PartialEq` since `Message` never contains
            // any IPC objects.
            //
            // It also theoretically allows multiple requests to work in parallel,
            // but I won't implement that right away.

            let (response_tx, response_rx) = ipc::channel::<Message>().unwrap();
            tx.send((Message::Connect, response_tx)).unwrap();
            assert_eq!(
                response_rx.try_recv_timeout(timeout).unwrap(),
                Message::Connected
            );

            let (response_tx, response_rx) = ipc::channel().unwrap();
            tx.send((Message::AwaitCallback, response_tx)).unwrap();
            assert_eq!(
                response_rx.try_recv_timeout(timeout).unwrap(),
                Message::Callback
            );

            let (response_tx, response_rx) = ipc::channel().unwrap();
            tx.send((Message::Disconnect, response_tx)).unwrap();
            assert_eq!(
                response_rx.try_recv_timeout(timeout).unwrap(),
                Message::Disconnected
            );

            // Make sure the worker 'process' exited
            worker_task.await.unwrap();

            let elapsed = start_time.elapsed();

            // We sleep for 2 seconds in AwaitCallback, so this is expected
            let required_ms = 2000;

            // Give the IPC stuff up to X ms of overhead to complete 3 requests
            let slack_ms = 100;
            assert!(
                elapsed <= Duration::from_millis(required_ms + slack_ms),
                "{:?}",
                elapsed
            );

            // TODO: Test that killing the worker process wakes up `recv` calls

            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }
}
