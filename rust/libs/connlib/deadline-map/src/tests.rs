use std::time::Duration;

use super::*;

struct Value(Option<Instant>);

impl PollTimeout for Value {
    fn poll_timeout(&mut self) -> Option<Instant> {
        self.0
    }
}

fn reindexed(map: &mut DeadlineMap<u32, Value>) -> Vec<u32> {
    let mut keys = Vec::new();
    map.reindex(|k, _| keys.push(k));
    keys.sort();

    keys
}

#[test]
fn poll_timeout_follows_deadline_moving_earlier_and_later() {
    let now = Instant::now();
    let mut map = DeadlineMap::default();
    map.insert(1, Value(Some(now + Duration::from_secs(5))));
    map.insert(2, Value(Some(now + Duration::from_secs(3))));

    assert_eq!(map.poll_timeout(), Some(now + Duration::from_secs(3)));

    map.get_mut(&1).unwrap().0 = Some(now + Duration::from_secs(1));
    assert_eq!(map.poll_timeout(), Some(now + Duration::from_secs(1)));

    map.get_mut(&1).unwrap().0 = Some(now + Duration::from_secs(10));
    assert_eq!(map.poll_timeout(), Some(now + Duration::from_secs(3)));

    map.get_mut(&2).unwrap().0 = None;
    assert_eq!(map.poll_timeout(), Some(now + Duration::from_secs(10)));
}

#[test]
fn only_mutable_access_marks() {
    let mut map = DeadlineMap::default();
    map.insert(1, Value(None));
    map.insert(2, Value(None));
    map.insert(3, Value(None));
    assert_eq!(reindexed(&mut map), vec![1, 2, 3]);

    let _ = map.get(&1);
    let _ = map.iter().count();
    assert_eq!(reindexed(&mut map), Vec::<u32>::new());

    let _ = map.get_mut(&1);
    assert_eq!(reindexed(&mut map), vec![1]);

    for _ in map.filter_mut(|v| v.0.is_none()).take(1) {}
    assert_eq!(reindexed(&mut map).len(), 1);

    for _ in map.iter_mut() {}
    assert_eq!(reindexed(&mut map), vec![1, 2, 3]);
}

#[test]
fn handle_timeout_visits_marked_then_due_in_deadline_order() {
    let now = Instant::now();
    let mut map = DeadlineMap::default();
    map.insert(1, Value(Some(now + Duration::from_secs(2))));
    map.insert(2, Value(Some(now + Duration::from_secs(1))));
    map.insert(3, Value(Some(now + Duration::from_secs(3))));
    map.insert(4, Value(Some(now + Duration::from_secs(10))));
    map.reindex(|_, _| {});

    let _ = map.get_mut(&4);
    let visited = map.handle_timeout(now + Duration::from_secs(3), |_, _| {});

    assert_eq!(visited, vec![4, 2, 1, 3]);
}

#[test]
fn handle_timeout_leaves_visited_entries_marked() {
    let now = Instant::now();
    let mut map = DeadlineMap::default();
    map.insert(1, Value(Some(now)));
    map.insert(2, Value(Some(now + Duration::from_secs(1))));
    map.reindex(|_, _| {});

    let visited = map.handle_timeout(now, |_, v| v.0 = None);

    assert_eq!(visited, vec![1]);
    assert_eq!(reindexed(&mut map), vec![1]);
    assert_eq!(map.poll_timeout(), Some(now + Duration::from_secs(1)));
}

#[test]
fn removal_unindexes() {
    let now = Instant::now();
    let mut map = DeadlineMap::default();
    map.insert(1, Value(Some(now)));
    map.insert(2, Value(Some(now + Duration::from_secs(1))));
    map.reindex(|_, _| {});

    map.remove(&1);
    assert_eq!(map.poll_timeout(), Some(now + Duration::from_secs(1)));

    let removed = map.extract_if(|k, _| *k == 2);
    assert_eq!(removed.len(), 1);
    assert_eq!(map.poll_timeout(), None);
    assert!(
        map.handle_timeout(now + Duration::from_secs(1), |_, _| {})
            .is_empty()
    );
}

#[test]
fn removal_unmarks() {
    let mut map = DeadlineMap::default();
    map.insert(1, Value(None));
    map.remove(&1);

    assert_eq!(reindexed(&mut map), Vec::<u32>::new());
}
