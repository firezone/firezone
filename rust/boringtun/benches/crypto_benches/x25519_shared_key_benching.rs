use criterion::{BatchSize, Criterion};
use rand_core::OsRng;

pub fn bench_x25519_shared_key(c: &mut Criterion) {
    let mut group = c.benchmark_group("x25519_shared_key");

    group.sample_size(1000);

    group.bench_function("x25519_shared_key_dalek", |b| {
        let public_key =
            x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::random_from_rng(OsRng));

        b.iter_batched(
            || x25519_dalek::StaticSecret::random_from_rng(OsRng),
            |secret_key| secret_key.diffie_hellman(&public_key),
            BatchSize::SmallInput,
        );
    });

    group.bench_function("x25519_shared_key_ring", |b| {
        let rng = ring::rand::SystemRandom::new();

        let peer_public_key = {
            let peer_private_key =
                ring::agreement::EphemeralPrivateKey::generate(&ring::agreement::X25519, &rng)
                    .unwrap();
            peer_private_key.compute_public_key().unwrap()
        };
        let peer_public_key_alg = &ring::agreement::X25519;

        let my_public_key =
            ring::agreement::UnparsedPublicKey::new(peer_public_key_alg, &peer_public_key);

        b.iter_batched(
            || {
                ring::agreement::EphemeralPrivateKey::generate(&ring::agreement::X25519, &rng)
                    .unwrap()
            },
            |my_private_key| {
                ring::agreement::agree_ephemeral(my_private_key, &my_public_key, |_key_material| ())
                    .unwrap()
            },
            BatchSize::SmallInput,
        );
    });

    group.finish();
}
