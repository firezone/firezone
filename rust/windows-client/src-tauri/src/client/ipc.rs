//! Inter-process communication for the connlib subprocess

#[cfg(test)]
mod tests {
    use connlib_client_shared::ResourceDescription;
    use serde::{de::DeserializeOwned, Deserialize, Serialize};
    use std::marker::Unpin;
    use tokio::{
        io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
        net::windows::named_pipe,
        runtime::Runtime,
    };

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

    #[derive(Deserialize, Serialize)]
    enum Request {
        AwaitCallback,
        Connect,
        Disconnect,
    }

    #[derive(Debug, Deserialize, PartialEq, Serialize)]
    enum Response {
        CallbackOnUpdateResources(Vec<ResourceDescription>),
        Connected,
        Disconnected,
    }

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

    /// Reads a message from an async reader, with a 32-bit little-endian length prefix
    async fn read_bincode<R: AsyncRead + Unpin, T: DeserializeOwned>(
        reader: &mut R,
    ) -> anyhow::Result<T> {
        let mut len_buf = [0u8; 4];
        reader.read_exact(&mut len_buf).await?;
        let len = u32::from_le_bytes(len_buf);
        let mut buf = vec![0u8; usize::try_from(len)?];
        reader.read_exact(&mut buf).await?;
        let msg = bincode::deserialize(&buf)?;
        Ok(msg)
    }

    /// Writes a message to an async writer, with a 32-bit little-endian length prefix
    async fn write_bincode<W: AsyncWrite + Unpin, T: Serialize>(
        writer: &mut W,
        msg: &T,
    ) -> anyhow::Result<()> {
        let buf = bincode::serialize(msg)?;
        let len = u32::try_from(buf.len())?.to_le_bytes();
        writer.write_all(&len).await?;
        writer.write_all(&buf).await?;
        Ok(())
    }

    impl Server {
        pub async fn request(&mut self, req: Request) -> anyhow::Result<Response> {
            write_bincode(&mut self.pipe, &req).await?;
            read_bincode(&mut self.pipe).await
        }
    }

    impl Client {
        pub fn new(server_id: &str) -> anyhow::Result<Self> {
            let pipe = named_pipe::ClientOptions::new().open(server_id)?;
            Ok(Self { pipe })
        }

        pub async fn next_request(&mut self) -> anyhow::Result<(Request, Responder)> {
            let req = read_bincode(&mut self.pipe).await?;
            let responder = Responder { client: self };
            Ok((req, responder))
        }
    }

    impl<'a> Responder<'a> {
        pub async fn respond(self, resp: Response) -> anyhow::Result<()> {
            write_bincode(&mut self.client.pipe, &resp).await?;
            Ok(())
        }
    }

    /// Test just the happy path
    /// It's hard to simulate a process crash because:
    /// - If I Drop anything, Tokio will clean it up
    /// - If I `std::mem::forget` anything, the test process is still runnig, so Windows will not clean it up
    ///
    /// TODO: Simulate crashes of processes involved in IPC using our own test framework
    #[test]
    fn happy_path() -> anyhow::Result<()> {
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
                    let resp = match &req {
                        Request::AwaitCallback => Response::CallbackOnUpdateResources(vec![]),
                        Request::Connect => Response::Connected,
                        Request::Disconnect => Response::Disconnected,
                    };
                    responder.respond(resp).await?;

                    if let Request::Disconnect = req {
                        break;
                    }
                }
                Ok::<_, anyhow::Error>(())
            });

            let mut server = server.connect().await?;

            let start_time = std::time::Instant::now();
            assert_eq!(server.request(Request::Connect).await?, Response::Connected);
            assert_eq!(
                server.request(Request::AwaitCallback).await?,
                Response::CallbackOnUpdateResources(vec![])
            );
            assert_eq!(
                server.request(Request::Disconnect).await?,
                Response::Disconnected
            );

            let elapsed = start_time.elapsed();
            assert!(
                elapsed < std::time::Duration::from_millis(6),
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
