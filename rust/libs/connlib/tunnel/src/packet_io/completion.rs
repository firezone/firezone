//! A local packet transport whose operations are completed by a host event loop.

use super::*;
use std::{
    cell::RefCell,
    collections::{BTreeMap, VecDeque},
    rc::Rc,
    task::Waker,
};

const CAPACITY: usize = 32;

pub struct CompletionIo(Rc<RefCell<Queues>>);

#[derive(Clone)]
pub struct CompletionPort(Rc<RefCell<Queues>>);

pub struct Operation {
    pub id: u64,
    pub generation: u64,
    pub payload: Payload,
}

pub enum Payload {
    Network(DatagramOut),
    Tun(PacketBatch),
    Rebind,
}

struct Queues {
    network: VecDeque<ReceivedDatagram>,
    tun: VecDeque<PacketBatch>,
    output: VecDeque<Payload>,
    current_tun: PacketBatch,
    in_flight: BTreeMap<u64, u64>,
    errors: VecDeque<anyhow::Error>,
    next_id: u64,
    generation: u64,
    closed: bool,
    state_waker: Option<Waker>,
    host_waker: Option<Waker>,
    receive_network_waker: Option<Waker>,
    receive_tun_waker: Option<Waker>,
}

impl CompletionIo {
    pub fn new() -> (Self, CompletionPort) {
        let queues = Rc::new(RefCell::new(Queues {
            network: VecDeque::new(),
            tun: VecDeque::new(),
            output: VecDeque::new(),
            current_tun: PacketBatch::default(),
            in_flight: BTreeMap::new(),
            errors: VecDeque::new(),
            next_id: 1,
            generation: 0,
            closed: false,
            state_waker: None,
            host_waker: None,
            receive_network_waker: None,
            receive_tun_waker: None,
        }));
        (Self(queues.clone()), CompletionPort(queues))
    }
}

impl CompletionPort {
    pub fn generation(&self) -> u64 {
        self.0.borrow().generation
    }

    pub fn poll_receive_ready(&self, cx: &mut Context<'_>, network: bool) -> Poll<()> {
        let mut queues = self.0.borrow_mut();
        if network {
            if queues.network.len() < CAPACITY {
                return Poll::Ready(());
            }
            queues.receive_network_waker = Some(cx.waker().clone());
        } else {
            if queues.tun.len() < CAPACITY {
                return Poll::Ready(());
            }
            queues.receive_tun_waker = Some(cx.waker().clone());
        }
        Poll::Pending
    }

    pub fn receive_network(&self, generation: u64, batch: ReceivedDatagram) -> Result<()> {
        let mut queues = self.0.borrow_mut();
        if generation != queues.generation {
            return Ok(());
        }
        anyhow::ensure!(!queues.closed, "Completion transport closed");
        anyhow::ensure!(queues.network.len() < CAPACITY, "Network input queue full");
        queues.network.push_back(batch);
        queues.wake_state();
        Ok(())
    }

    pub fn receive_tun(&self, generation: u64, batch: PacketBatch) -> Result<()> {
        let mut queues = self.0.borrow_mut();
        if generation != queues.generation {
            return Ok(());
        }
        anyhow::ensure!(!queues.closed, "Completion transport closed");
        anyhow::ensure!(queues.tun.len() < CAPACITY, "TUN input queue full");
        queues.tun.push_back(batch);
        queues.wake_state();
        Ok(())
    }

    pub fn poll_operation(&self, cx: &mut Context<'_>) -> Poll<Option<Operation>> {
        let mut queues = self.0.borrow_mut();
        queues.host_waker = Some(cx.waker().clone());
        let Some(payload) = queues.output.pop_front() else {
            return if queues.closed {
                Poll::Ready(None)
            } else {
                Poll::Pending
            };
        };
        let id = queues.next_id;
        queues.next_id = queues
            .next_id
            .checked_add(1)
            .expect("Operation IDs exhausted");
        let generation = queues.generation;
        queues.in_flight.insert(id, generation);
        Poll::Ready(Some(Operation {
            id,
            generation: queues.generation,
            payload,
        }))
    }

    /// Acknowledges processing separately from releasing the operation's storage.
    pub fn complete(&self, id: u64, result: Result<()>) -> Result<()> {
        let mut queues = self.0.borrow_mut();
        let generation = queues
            .in_flight
            .remove(&id)
            .ok_or_else(|| anyhow::anyhow!("Unknown or duplicate completion"))?;
        if generation == queues.generation
            && let Err(error) = result
        {
            queues.errors.push_back(error);
        }
        queues.wake_state();
        Ok(())
    }

    #[cfg(any(target_os = "linux", target_os = "windows", target_os = "android"))]
    pub(crate) fn report_error(&self, error: anyhow::Error) {
        let mut queues = self.0.borrow_mut();
        queues.errors.push_back(error);
        queues.wake_state();
    }

    pub fn close(&self) {
        let mut queues = self.0.borrow_mut();
        queues.closed = true;
        queues.wake_state();
        queues.wake_host();
    }
}

impl PacketIo for CompletionIo {
    type Network = ReceivedNetwork;
    fn poll_network(&mut self, cx: &mut Context<'_>) -> Poll<ReceivedNetwork> {
        let mut queues = self.0.borrow_mut();
        queues.state_waker = Some(cx.waker().clone());
        if queues.network.is_empty() {
            return Poll::Pending;
        }
        let network = std::mem::take(&mut queues.network);
        if let Some(waker) = queues.receive_network_waker.take() {
            waker.wake();
        }
        Poll::Ready(ReceivedNetwork(network))
    }
    fn poll_tun(&mut self, cx: &mut Context<'_>) -> Poll<Result<PacketBatch>> {
        let mut queues = self.0.borrow_mut();
        queues.state_waker = Some(cx.waker().clone());
        let batch = queues.tun.pop_front();
        if let Some(waker) = queues.receive_tun_waker.take() {
            waker.wake();
        }
        match batch {
            Some(batch) => Poll::Ready(Ok(batch)),
            None if queues.closed => Poll::Ready(Err(super::PacketIoFailed(anyhow::anyhow!(
                "Completion transport closed"
            ))
            .into())),
            None => Poll::Pending,
        }
    }
    fn poll_error(&mut self, _: &mut Context<'_>) -> Poll<anyhow::Error> {
        match self.0.borrow_mut().errors.pop_front() {
            Some(error) => Poll::Ready(error),
            None => Poll::Pending,
        }
    }
    fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        let mut queues = self.0.borrow_mut();
        queues.state_waker = Some(cx.waker().clone());
        if queues.output.len() + queues.in_flight.len() >= CAPACITY {
            return Poll::Pending;
        }
        Poll::Ready(Ok(()))
    }
    fn send(&mut self, datagram: DatagramOut) -> Result<()> {
        let mut queues = self.0.borrow_mut();
        queues.output.push_back(Payload::Network(datagram));
        queues.wake_host();
        Ok(())
    }
    fn queue_tun(&mut self, packet: IpPacket) {
        let mut queues = self.0.borrow_mut();
        if let Err(packet) = queues.current_tun.try_push(packet) {
            let batch = std::mem::replace(&mut queues.current_tun, PacketBatch::new(packet));
            queues.output.push_back(Payload::Tun(batch));
        }
    }
    fn flush_tun_batch(&mut self) {
        let mut queues = self.0.borrow_mut();
        if queues.current_tun.is_empty() {
            return;
        }
        let batch = std::mem::take(&mut queues.current_tun);
        queues.output.push_back(Payload::Tun(batch));
        queues.wake_host();
    }
    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        self.poll_send_ready(cx)
    }
    fn poll_shutdown(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        let mut queues = self.0.borrow_mut();
        queues.state_waker = Some(cx.waker().clone());
        if !queues.output.is_empty() || !queues.in_flight.is_empty() {
            return Poll::Pending;
        }
        Poll::Ready(Ok(()))
    }
    fn set_tun(&mut self, _: Box<dyn Tun>) {
        self.0
            .borrow_mut()
            .errors
            .push_back(anyhow::anyhow!("Completion transport uses host TUN I/O"));
    }
    fn reset(&mut self, _: Arc<dyn SocketFactory<UdpSocket>>) {
        let mut queues = self.0.borrow_mut();
        queues.generation += 1;
        queues.network.clear();
        queues.tun.clear();
        queues.output.clear();
        queues.current_tun = PacketBatch::default();
        queues.output.push_back(Payload::Rebind);
        queues.wake_host();
    }
}

impl Queues {
    fn wake_state(&mut self) {
        if let Some(waker) = self.state_waker.take() {
            waker.wake();
        }
    }
    fn wake_host(&mut self) {
        if let Some(waker) = self.host_waker.take() {
            waker.wake();
        }
    }
}

/// Owns a datagram's storage, including immutable buffers retained by an FFI host.
pub struct ReceivedDatagram {
    pub storage: Box<dyn AsRef<[u8]>>,
    pub local: std::net::SocketAddr,
    pub from: std::net::SocketAddr,
    pub stride: usize,
    pub ecn: ip_packet::Ecn,
}

pub struct ReceivedNetwork(VecDeque<ReceivedDatagram>);

impl super::NetworkInput for ReceivedNetwork {
    fn for_each(&mut self, mut callback: impl FnMut(socket_factory::DatagramIn<'_>)) {
        for received in self.0.drain(..) {
            let bytes = received.storage.as_ref().as_ref();
            if received.stride == 0 {
                continue;
            }
            for packet in bytes.chunks(received.stride) {
                callback(socket_factory::DatagramIn {
                    local: received.local,
                    from: received.from,
                    packet,
                    ecn: received.ecn,
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::Cell, net::Ipv4Addr};

    #[test]
    fn completion_applies_backpressure_without_reclaiming_storage() {
        let (mut io, port) = CompletionIo::new();
        let mut cx = Context::from_waker(futures::task::noop_waker_ref());
        let pool = bufferpool::BufferPool::<Vec<u8>>::new(1, "test-completion");

        for value in 0..CAPACITY {
            let mut packet = pool.pull();
            packet.clear();
            packet.push(value as u8);
            io.send(DatagramOut {
                src: None,
                dst: "127.0.0.1:1234".parse().unwrap(),
                packet,
                segment_size: 1,
                ecn: ip_packet::Ecn::NonEct,
            })
            .unwrap();
        }
        assert!(io.poll_send_ready(&mut cx).is_pending());
        let Poll::Ready(Some(first)) = port.poll_operation(&mut cx) else {
            panic!("Expected operation");
        };
        assert!(io.poll_send_ready(&mut cx).is_pending());
        assert!(io.poll_shutdown(&mut cx).is_pending());

        port.complete(first.id, Ok(())).unwrap();
        assert!(io.poll_send_ready(&mut cx).is_ready());
        let Payload::Network(datagram) = first.payload else {
            panic!("Expected datagram");
        };
        assert_eq!(&*datagram.packet, &[0]);
        assert!(port.complete(first.id, Ok(())).is_err());

        for value in 1..CAPACITY {
            let Poll::Ready(Some(operation)) = port.poll_operation(&mut cx) else {
                panic!("Expected operation");
            };
            let Payload::Network(datagram) = operation.payload else {
                panic!("Expected datagram");
            };
            assert_eq!(&*datagram.packet, &[value as u8]);
            port.complete(operation.id, Ok(())).unwrap();
        }
        assert!(io.poll_shutdown(&mut cx).is_ready());
        assert_eq!(&*datagram.packet, &[0]);
    }

    #[test]
    fn reset_discards_stale_receives_and_completions_without_invalidating_leases() {
        let (mut io, port) = CompletionIo::new();
        let mut cx = Context::from_waker(futures::task::noop_waker_ref());
        let packet =
            ip_packet::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 1, 2, &[42])
                .unwrap();
        io.queue_tun(packet.clone());
        io.flush_tun_batch();
        let Poll::Ready(Some(operation)) = port.poll_operation(&mut cx) else {
            panic!("Expected operation");
        };

        io.reset(Arc::new(socket_factory::udp));
        let released = Rc::new(Cell::new(false));
        port.receive_network(
            0,
            ReceivedDatagram {
                storage: Box::new(TrackedBytes(released.clone())),
                local: "127.0.0.1:1".parse().unwrap(),
                from: "127.0.0.1:2".parse().unwrap(),
                stride: 1,
                ecn: ip_packet::Ecn::NonEct,
            },
        )
        .unwrap();
        port.complete(operation.id, Err(anyhow::anyhow!("cancelled old socket")))
            .unwrap();

        assert!(released.get());
        assert!(io.poll_network(&mut cx).is_pending());
        assert!(io.poll_error(&mut cx).is_pending());
        let Payload::Tun(batch) = operation.payload else {
            panic!("Expected TUN batch");
        };
        assert_eq!(batch[0], packet);
        let Poll::Ready(Some(rebind)) = port.poll_operation(&mut cx) else {
            panic!("Expected rebind");
        };
        assert!(matches!(rebind.payload, Payload::Rebind));
        assert_eq!(rebind.generation, 1);
        port.complete(rebind.id, Ok(())).unwrap();
    }

    struct TrackedBytes(Rc<Cell<bool>>);
    impl AsRef<[u8]> for TrackedBytes {
        fn as_ref(&self) -> &[u8] {
            &[1]
        }
    }
    impl Drop for TrackedBytes {
        fn drop(&mut self) {
            self.0.set(true);
        }
    }
}
