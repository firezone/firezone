# Fuzzing

One executable exercises four targets, each with its own corpus:

- `ip-packet`: packet parsing and mutation.
- `relay-proto`: relay message handling, including authenticated requests.
- `tunnel-proto`: tunnel behavior checked against a reference model.
- `x509-claims`: certificate parsing and identity claims.

## Execution model

[AFL++](https://github.com/AFLplusplus/AFLplusplus) discovers inputs through a forkserver, running each input in a fresh child process.
Each parent initializes the same RNG seeds and simulation clock anchor, and children inherit that state.
In-memory state left by one input cannot affect another; external state is not reset.

Replay runs saved inputs in persistent batches for speed, using the same target functions and assertions as discovery.
Any failing input fails the replay.
Because replay retains process state between inputs, it checks regressions but does not establish discovery determinism.

## Corpora

Each target's inputs are committed under `corpus/<target>`; they serve as regression tests and starting points for further discovery.
Discovery adds an input only when it reaches an edge the committed corpus does not; it never removes committed inputs.
Minimization retains inputs that contribute edge coverage or fuzzer feedback; differences in execution counts alone do not justify retaining an input.
AFL edge coverage and IJON feedback guide discovery and minimization.

The tunnel-proto feedback pass records [IJON feedback](https://github.com/AFLplusplus/AFLplusplus/blob/stable/docs/IJON.md) for meaningful observed states, such as an ICMP error successfully translated through gateway NAT back to the client.
Each distinct value recorded at an annotation site is a feature scoped to that site; recording the same value again does not add feedback.
Replay evaluates annotations without recording feedback.

Pull-request CI checks that discovery coverage is stable within and across forkservers and replays the committed corpora.
The [nightly workflow](../../../.github/workflows/fuzz-nightly.yml) grows corpora and retains failing inputs for regression testing; the [monthly workflow](../../../.github/workflows/fuzz-cmin.yml) minimizes them.
On the default branch they propose corpus PRs; dispatching either on another branch pushes results back to that branch.
Use the nightly workflow when changes require new inputs, including changes to how the tunnel generator interprets existing inputs, and the monthly one when changes make existing inputs redundant.

## Usage

The tasks support x86-64 Linux.
Install the tools declared in [mise.toml](mise.toml), then select a target:

```console
mise install --cd rust/tests/fuzz
mise run //rust/tests/fuzz:fuzz ip-packet --seconds 60
mise run //rust/tests/fuzz:replay ip-packet
mise run //rust/tests/fuzz:replay ip-packet --repeat 100
```

Discovery requires `--seconds` and accepts `--workers`; replay reports iterations per second.
For local discovery, follow AFL++'s startup diagnostics for host configuration.

To minimize and investigate a saved crash:

```console
mise run //rust/tests/fuzz:tmin tunnel-proto artifacts/tunnel-proto/crashes-<hash>
mise run //rust/tests/fuzz:repro tunnel-proto artifacts/tunnel-proto/crashes-<hash>.minimized
```

`repro` enables debug tracing; set `RUST_LOG=trace` for more detail.

To minimize a corpus by hand, e.g. after a harness rewrite made inputs redundant:

```console
mise run //rust/tests/fuzz:cmin tunnel-proto
```

## Querying the corpus

Replaying the tunnel-proto corpus can write what each input generates as JSON Lines, one file per entity, into the git-ignored `json` directory.
[sql/tunnel-proto.sql](sql/tunnel-proto.sql) defines a DuckDB view per file.
IDs are counters that restart in every input, so every row carries its `input` and joins match on it:

```console
mise run //rust/tests/fuzz:emit-json tunnel-proto
mise run //rust/tests/fuzz:query tunnel-proto "SELECT count(DISTINCT input) FROM transitions WHERE kind = 'RoamClient'"
mise run //rust/tests/fuzz:query tunnel-proto "
  SELECT input, step, r.address
  FROM (SELECT input, step, unnest(dns_resources) AS id FROM dns_queries)
  JOIN resources r USING (input, id)
  WHERE r.address LIKE '**%'"
```

`dns_queries` and `probes` list the DNS resources matching a queried name in the order the reference model prefers them.
Run `duckdb -init sql/tunnel-proto.sql` in this directory to query interactively.
Rerun `emit-json` after changing the corpus or the harness.
