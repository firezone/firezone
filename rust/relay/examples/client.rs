use anyhow::{anyhow, Result};
use redis::AsyncCommands;
use std::future::poll_fn;
use std::net::SocketAddr;
use std::task::Poll;
use std::time::Duration;
use stun_codec::rfc5389::attributes::Username;
use tokio::io::ReadBuf;
use tokio::net::UdpSocket;

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    let redis_client = redis::Client::open("redis://localhost:6379")?;
    let mut redis_connection = redis_client.get_async_connection().await?;

    tokio::time::sleep(Duration::from_millis(100)).await;

    let socket = UdpSocket::bind("127.0.0.1:0").await?;
    let relay_addr = "127.0.0.1:3478".parse()?;

    let mut buf = [0u8; 65536];

    let gateway_addr = redis_connection
        .blpop::<_, (String, String)>("gateway_addr", 10)
        .await?
        .1
        .parse::<SocketAddr>()?;

    println!("Retrieved gateway address: {gateway_addr}");

    let mut allocation = firezone_relay::client::Allocation::new(
        relay_addr,
        Username::new("2000000000:client".to_owned()).unwrap(),
        "+Qou8TSjw9q3JMnWET7MbFsQh/agwz/LURhpfX7a0hE".to_owned(),
    );

    poll_fn(|cx| loop {
        let mut buf = ReadBuf::new(&mut buf);
        if let Poll::Ready(from) = socket.poll_recv_from(cx, &mut buf)? {
            if allocation.handle_input(from, buf.filled()) && allocation.mapped_address().is_some()
            {
                break Poll::Ready(anyhow::Ok(()));
            }
            continue;
        }

        if let Poll::Ready(transmit) = allocation.poll(cx) {
            socket.try_send_to(&transmit.payload, transmit.dst)?;
            continue;
        }

        return Poll::Pending;
    })
    .await?;

    let binding = allocation.bind_channel(gateway_addr).unwrap();

    redis_connection
        .rpush::<_, _, ()>(
            "client_relay_addr",
            allocation.ip4_socket().unwrap().to_string(),
        )
        .await
        .unwrap();

    poll_fn::<Result<()>, _>(|cx| loop {
        let mut buf = ReadBuf::new(&mut buf);
        match socket.poll_recv_from(cx, &mut buf)? {
            Poll::Ready(from) => {
                let packet = buf.filled();
                if allocation.handle_input(from, packet) {
                    continue;
                }

                if binding.decapsulate(from, packet).is_some() {
                    socket.try_send_to(buf.filled(), from)?;
                    continue;
                };

                return Poll::Ready(Err(anyhow!("Unexpected traffic from {from}")));
            }
            Poll::Pending => {}
        }

        match allocation.poll(cx) {
            Poll::Ready(transmit) => {
                socket.try_send_to(&transmit.payload, transmit.dst)?;
                continue;
            }
            Poll::Pending => {}
        }

        return Poll::Pending;
    })
    .await?;

    Ok(())
}
