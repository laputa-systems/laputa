use std::collections::VecDeque;

#[derive(Debug, Default)]
pub struct QueueScheduler {
    queue: VecDeque<usize>,
    in_queue: Vec<bool>,
}

impl QueueScheduler {
    pub fn new(edge_count: usize) -> Self {
        Self {
            queue: VecDeque::new(),
            in_queue: vec![false; edge_count],
        }
    }

    pub fn push_ready(&mut self, idx: usize) {
        if idx < self.in_queue.len() && !self.in_queue[idx] {
            self.in_queue[idx] = true;
            self.queue.push_back(idx);
        }
    }

    pub fn pop(&mut self) -> Option<usize> {
        let idx = self.queue.pop_front()?;
        self.in_queue[idx] = false;
        Some(idx)
    }

    pub fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }
}

// Queue rather than a fresh full scan per dispatch: pull next ready edge
// in order pushed (producers complete), preserving dependency order.

pub fn execute(state: &graph::State, opts: &ninja::cli::Options) -> Result<u8, String> {
    ninja::build::run(state, opts)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_fifo_and_dedup() {
        let mut q = QueueScheduler::new(3);
        q.push_ready(1);
        q.push_ready(1);
        q.push_ready(2);
        assert_eq!(q.pop(), Some(1));
        assert_eq!(q.pop(), Some(2));
        assert!(q.is_empty());
    }
}
