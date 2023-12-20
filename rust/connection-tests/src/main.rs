use std::{net::IpAddr, str::FromStr};

use anyhow::{bail, Context, Result};
use boringtun::x25519::StaticSecret;
use firezone_connection::{ClientConnectionPool, ServerConnectionPool};
use tokio::net::UdpSocket;

#[tokio::main]
async fn main() -> Result<()> {
    let role = std::env::var("ROLE")
        .context("Missing ROLE env variable")?
        .parse::<Role>()?;
    let listen_addr = std::env::var("LISTEN_ADDR")
        .context("Missing LISTEN_ADDR env var")?
        .parse::<IpAddr>()?;

    let socket = UdpSocket::bind((listen_addr, 0)).await?;
    let socket_addr = socket.local_addr()?;
    let private_key = StaticSecret::random_from_rng(&mut rand::thread_rng());

    match role {
        Role::Dialer => {
            let mut pool = ClientConnectionPool::<u64>::new(private_key);
            pool.add_local_interface(socket_addr);

            let offer = pool.new_connection(1, vec![], vec![]);
        }
        Role::Listener => {
            let mut pool = ServerConnectionPool::<u64>::new(private_key);
            pool.add_local_interface(socket_addr);
        }
    };

    Ok(())
}

enum Role {
    Dialer,
    Listener,
}

impl FromStr for Role {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "dialer" => Ok(Self::Dialer),
            "listener" => Ok(Self::Listener),
            other => bail!("unknown role: {other}"),
        }
    }
}
