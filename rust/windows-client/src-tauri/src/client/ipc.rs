//! Inter-process communication for the connlib subprocess

#[cfg(test)]
mod tests {
    use serde::{Deserialize, Serialize};
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::windows::named_pipe,
        runtime::Runtime,
    };

    #[derive(Debug, Deserialize, PartialEq, Serialize)]
    enum Message {
        AwaitCallback,
        Callback,
        Connect,
        Connected,
        Disconnect,
        Disconnected,
    }

    /// Returns a random valid named pipe ID based on a UUIDv4
    ///
    /// e.g. "\\.\pipe\dev.firezone.client\9508e87c-1c92-4630-bb20-839325d169bd"
    fn random_pipe_id() -> String {
        format!(r"\\.\pipe\dev.firezone.client\{}", uuid::Uuid::new_v4())
    }

    /// A server that accepts only one client
    struct UnconnectedServer {
        pipe: named_pipe::NamedPipeServer,
    }

    /// A server that's connected to a client
    struct Server {
        pipe: named_pipe::NamedPipeServer,
    }

    /// A client that's connected to a server
    struct Client {
        pipe: named_pipe::NamedPipeClient,
    }

    struct Request(u8);
    struct Response(u8);

    #[must_use]
    struct Responder<'a> {
        client: &'a mut Client,
    }

    impl UnconnectedServer {
        pub fn new() -> anyhow::Result<(Self, String)> {
            let id = random_pipe_id();
            let pipe = named_pipe::ServerOptions::new()
                .first_pipe_instance(true)
                .create(&id)?;

            let this = Self { pipe };
            Ok((this, id))
        }

        pub async fn connect(self) -> anyhow::Result<Server> {
            self.pipe.connect().await?;
            Ok(Server { pipe: self.pipe })
        }
    }

    impl Server {
        pub async fn request(&mut self, req: Request) -> anyhow::Result<Response> {
            let buf = [req.0];
            self.pipe.write_all(&buf).await?;
            let mut buf = [0];
            self.pipe.read_exact(&mut buf).await?;
            Ok(Response(buf[0]))
        }
    }

    impl Client {
        pub fn new(server_id: &str) -> anyhow::Result<Self> {
            let pipe = named_pipe::ClientOptions::new().open(server_id)?;
            Ok(Self { pipe })
        }

        pub async fn next_request(&mut self) -> anyhow::Result<(Request, Responder)> {
            let mut buf = [0];
            self.pipe.read_exact(&mut buf).await?;
            let req = Request(buf[0]);
            let responder = Responder { client: self };
            Ok((req, responder))
        }
    }

    impl<'a> Responder<'a> {
        pub async fn respond(self, response: Response) -> anyhow::Result<()> {
            let buf = [response.0];
            self.client.pipe.write_all(&buf).await?;
            Ok(())
        }
    }

    #[test]
    fn ipc() -> anyhow::Result<()> {
        let rt = Runtime::new()?;
        rt.block_on(async move {
            // Pretend we're in the main process
            let (server, server_id) = UnconnectedServer::new()?;

            let worker_task = tokio::spawn(async move {
                // Pretend we're in a worker process
                let mut client = Client::new(&server_id)?;

                // Handle requests from the main process
                loop {
                    let (req, responder) = client.next_request().await?;
                    responder.respond(Response(req.0 + 128)).await?;

                    if req.0 == 0 {
                        break;
                    }
                }
                Ok::<_, anyhow::Error>(())
            });

            let mut server = server.connect().await?;

            let start_time = std::time::Instant::now();
            assert_eq!(server.request(Request(1)).await?.0, 129);
            assert_eq!(server.request(Request(10)).await?.0, 138);
            assert_eq!(server.request(Request(0)).await?.0, 128);
            let elapsed = start_time.elapsed();
            assert!(
                elapsed < std::time::Duration::from_millis(3),
                "{:?}",
                elapsed
            );

            // Make sure the worker 'process' exited
            worker_task.await??;

            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }
}
