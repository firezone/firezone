#[derive(Debug)]
pub struct RingBuffer<T> {
    buffer: Vec<T>,
}

impl<T: PartialEq> RingBuffer<T> {
    pub fn new(capacity: usize) -> Self {
        RingBuffer {
            buffer: Vec::with_capacity(capacity),
        }
    }

    pub fn push(&mut self, item: T) {
        if self.buffer.len() == self.buffer.capacity() {
            // Remove the oldest element (at the beginning) if at capacity
            self.buffer.remove(0);
        }
        self.buffer.push(item);
    }

    pub fn pop(&mut self) -> Option<T> {
        self.buffer.pop()
    }

    pub fn clear(&mut self) {
        self.buffer.clear();
    }

    pub fn iter(&self) -> impl Iterator<Item = &T> + '_ {
        self.buffer.iter()
    }

    #[cfg(test)]
    fn inner(&self) -> &[T] {
        self.buffer.as_slice()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_push_within_capacity() {
        let mut buffer = RingBuffer::new(3);

        buffer.push(1);
        buffer.push(2);
        buffer.push(3);

        assert_eq!(buffer.inner(), &[1, 2, 3]);
    }

    #[test]
    fn test_push_exceeds_capacity() {
        let mut buffer = RingBuffer::new(2);

        buffer.push(1);
        buffer.push(2);
        buffer.push(3);

        assert_eq!(buffer.inner(), &[2, 3]);
    }
}
