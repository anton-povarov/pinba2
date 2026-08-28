# PostgreSQL wire-protocol server libraries

Research date: 2026-08-28.

## Scope

This note follows the PostgreSQL-wire decision in
[`network-report-interfaces.md`](network-report-interfaces.md). It looks only
for reusable **server-side** protocol implementations. A PostgreSQL client
driver, SQL parser, connection pooler, or protocol proxy does not satisfy the
requirement by itself.

Sources are upstream repositories, source code, package documentation,
releases, and licenses.

## Result

There is no mature, licensed, production-ready PostgreSQL wire-protocol server
library that can be linked directly into this C/C++ codebase.

The best actual server framework is Rust [`sunng87/pgwire`](https://github.com/sunng87/pgwire).
The best runner-up is Go [`jeroenrinzema/psql-wire`](https://github.com/jeroenrinzema/psql-wire).
Both avoid implementing the protocol state machine, but neither has a supported
C ABI. The only purpose-built C++ hit, [`euiko/pgwire`](https://github.com/euiko/pgwire),
is unlicensed, inactive, and substantially incomplete; it must not be adopted.

| Rank | Library | Language | Server framework | Verdict |
|---:|---|---|---|---|
| 1 | [`sunng87/pgwire`](https://github.com/sunng87/pgwire) | Rust | Yes | Best protocol coverage and maturity; use only if a Rust integration boundary is acceptable |
| 2 | [`jeroenrinzema/psql-wire`](https://github.com/jeroenrinzema/psql-wire) | Go | Yes | Credible implementation; weaker authentication and still needs a language/process boundary |
| Reject | [`euiko/pgwire`](https://github.com/euiko/pgwire) | C++17 | Nominally | No license, no releases, stale, and core advertised flows are not implemented |

If a single all-C++ process with no foreign-language build/runtime is a hard
constraint, the current library ecosystem cannot meet both that constraint and
the requirement not to implement or maintain PGWire ourselves. Allowing one
foreign-language component is therefore the meaningful choice, not whether a
thread per connection is acceptable.

## 1. Rust `sunng87/pgwire` — recommended library

### Why it ranks first

This is explicitly a library for PostgreSQL-compatible servers and clients,
with separate handler APIs for startup, simple query, extended query, COPY, and
cancellation. The server handlers are aggregated behind one
`PgWireServerHandlers` interface
([API overview](https://docs.rs/pgwire/latest/pgwire/)). Its upstream feature
list covers:

- protocol 3.0 and PostgreSQL 18 protocol 3.2 negotiation;
- PostgreSQL SSL negotiation, TCP/TLS, and PostgreSQL 17 direct TLS;
- trust/no-auth, cleartext, MD5, SCRAM-SHA-256, SCRAM-SHA-256-PLUS, and OAuth;
- simple query and the extended `Parse`/`Bind`/`Describe`/`Execute`/`Sync`
  flow, including prepared-statement and portal stores;
- cancellation, structured errors/notices, COPY, notification, and transaction
  state;
- text and binary values, with PostgreSQL type encoding delegated to
  `postgres-types`.

These are documented in the upstream
[`README`](https://github.com/sunng87/pgwire/blob/master/README.md#status) and
the published [`pgwire` API](https://docs.rs/pgwire/latest/pgwire/). Examples
exercise TLS, SCRAM, cancellation, simple and extended queries, transactions,
cursors, and COPY
([examples directory](https://github.com/sunng87/pgwire/tree/master/examples)).

The project is active and regularly released: the current package is 0.40.7,
and the upstream release history contains the full 0.40 line
([releases](https://github.com/sunng87/pgwire/releases)). Upstream also names
multiple real projects using it, including GreptimeDB, PeerDB, SpacetimeDB, and
Fly.io's Corrosion
([adopters](https://github.com/sunng87/pgwire#projects-using-pgwire)). It is
dual-licensed MIT/Apache-2.0
([MIT](https://github.com/sunng87/pgwire/blob/master/LICENSE-MIT),
[Apache-2.0](https://github.com/sunng87/pgwire/blob/master/LICENSE-APACHE)).

### Networking and dependencies

The supplied server runs on Tokio, not a blocking thread-per-connection API.
TLS uses `rustls` with either `aws-lc-rs` (default) or `ring`. The full manifest
also shows `tokio-util`, `futures`, authentication/crypto crates, and optional
type crates
([`Cargo.toml`](https://github.com/sunng87/pgwire/blob/master/Cargo.toml)).
Thread-per-client being acceptable does not simplify this particular library;
adopting its server API means accepting its Tokio runtime.

There is no upstream C header, `extern "C"` interface, or documented C/C++
embedding API. Pinba cannot directly link to its Rust API. A same-process use
would require a Pinba-owned Rust static-library/C-ABI wrapper and runtime
bridge; a separate executable would require an internal IPC contract. Either
is integration work, but neither is PGWire implementation work.

### Pinba-owned glue still required

The library owns protocol framing, state transitions, authentication flows,
TLS, statement/portal bookkeeping, encoders, cancellation dispatch, and error
messages. Pinba would still own:

- the Rust-to-C++ or process boundary;
- startup policy, credentials, advertised server parameters, and TLS
  configuration;
- simple- and extended-query handlers that call the Pinba SQL/parser/execution
  layer;
- mapping Pinba columns and values to PostgreSQL OIDs and text/binary formats;
- mapping Pinba failures to SQLSTATE/severity/detail/hint fields;
- connecting the library's cancellation token to running Pinba work;
- report snapshots, SQL semantics, `SET`/`SHOW`, `information_schema`, and the
  deliberately small `pg_catalog` compatibility surface.

The last item is unavoidable: PGWire carries messages and typed rows, not SQL
or catalog semantics
([upstream protocol explanation](https://docs.rs/pgwire/latest/pgwire/#about-the-postgres-wire-protocol)).

## 2. Go `jeroenrinzema/psql-wire` — credible runner-up

### Strengths

This is a high-level pure-Go **server** library. Its public `ParseFn` returns
prepared statements, and its APIs provide statement and portal caches, bind
parameters, row descriptions, text/binary formats, and result writers
([package API](https://pkg.go.dev/github.com/jeroenrinzema/psql-wire)). Source
and tests cover simple query plus extended `Parse`, `Bind`, `Describe`,
`Execute`, `Close`, `Flush`, and `Sync`, including portal suspension and error
recovery. Version 0.19.0 specifically fixed race conditions, fatal-error
handling, cache cleanup, and portal suspension
([release notes](https://github.com/jeroenrinzema/psql-wire/releases/tag/v0.19.0)).

It also supplies:

- PostgreSQL TLS upgrade and optional mTLS
  ([handshake source](https://github.com/jeroenrinzema/psql-wire/blob/main/handshake.go));
- `BackendKeyData` and cancellation callbacks
  ([server options](https://github.com/jeroenrinzema/psql-wire/blob/main/options.go));
- structured PostgreSQL error fields and SQLSTATE helpers
  ([errors package](https://pkg.go.dev/github.com/jeroenrinzema/psql-wire/errors));
- PostgreSQL type mapping via pgx `pgtype`
  ([row implementation](https://github.com/jeroenrinzema/psql-wire/blob/main/row.go));
- transaction status and per-session attributes.

It is actively maintained with a sequence of tagged releases
([releases](https://github.com/jeroenrinzema/psql-wire/releases)) and uses the
Apache-2.0 license
([license](https://github.com/jeroenrinzema/psql-wire/blob/main/LICENSE)).

### Limitations and integration cost

The built-in authentication choices are trust/no-auth and cleartext password.
`AuthStrategy` is extensible, but MD5 and SCRAM are not supplied
([authentication source](https://github.com/jeroenrinzema/psql-wire/blob/main/auth.go)).
Cleartext is acceptable only inside TLS; implementing SCRAM through its
low-level callback would add protocol/security code that the Rust option
already provides.

Its accept loop starts one Go goroutine per connection
([server source](https://github.com/jeroenrinzema/psql-wire/blob/main/wire.go)).
That is operationally close to the requested simple concurrency model, but it
is not an OS thread per client and it introduces the Go runtime. The runtime
implementation uses pgx/v5's `pgtype`; its module manifest also lists lib/pq
and supporting logging/test modules used by the test suite
([`go.mod`](https://github.com/jeroenrinzema/psql-wire/blob/main/go.mod)).

There is no supported C ABI. A Go `c-shared` wrapper around callbacks into C++
would be custom and awkward; a separate Go service is the cleaner supported
shape, but then Pinba needs IPC. The Pinba-owned SQL, catalog, type, error,
cancellation, and session glue listed for Rust remains required.

Choose this over Rust only when Go is already operationally preferred and
trust or cleartext-over-TLS authentication is enough.

## 3. C++ `euiko/pgwire` — reject

This repository is the only direct C++17 embeddable-server match found. Its
README advertises simple and extended query, COPY, replication, SSL, and
multiple authentication methods
([README](https://github.com/euiko/pgwire#features)), but its implementation
does not match those claims:

- only `Query` and `Terminate` frontend messages are registered for decoding;
- `Parse`, `Bind`, `Describe`, `Execute`, `Close`, `Sync`, and related messages
  fall through without handling;
- startup always emits `AuthenticationOk`;
- an SSL request receives the library's default negative response rather than
  starting TLS.

These behaviors are visible directly in
[`session.cpp`](https://github.com/euiko/pgwire/blob/main/src/pgwire/session.cpp)
and
[`protocol.hpp`](https://github.com/euiko/pgwire/blob/main/include/pgwire/protocol.hpp).
Its result writer buffers encoded rows in memory rather than providing a mature
streaming execution interface
([writer source](https://github.com/euiko/pgwire/blob/main/src/pgwire/writer.cpp)).

The repository has eight commits, no tagged releases, and no commits after
2024-11-20
([history](https://github.com/euiko/pgwire/commits/main/)). More importantly,
it has **no LICENSE file**, so there is no grant to copy, modify, distribute, or
link its code. It also brings standalone Asio plus endian, function2, and
promise-cpp submodules
([build file](https://github.com/euiko/pgwire/blob/main/CMakeLists.txt),
[submodules](https://github.com/euiko/pgwire/blob/main/.gitmodules)).

Language fit does not compensate for the legal and functional gaps. Completing
this library would be rolling and maintaining the protocol ourselves.

## Nearby projects that do not qualify

- PostgreSQL [`libpq`](https://www.postgresql.org/docs/current/libpq.html) and
  [`libpqxx`](https://github.com/jtv/libpqxx) are client libraries. They do not
  accept frontend connections or implement backend/server flows.
- [`PgBouncer`](https://github.com/pgbouncer/pgbouncer),
  [`pgagroal`](https://github.com/agroal/pgagroal), and
  [`Odyssey`](https://github.com/yandex/odyssey) are mature C/C++ proxy/pooler
  applications. Their protocol code is coupled to proxying a real PostgreSQL
  backend, not exposed as a query-handler server library. Extracting it means
  owning a fork and protocol integration.
- ClickHouse contains a working C++ PostgreSQL-compatible endpoint, but it is a
  component of the ClickHouse server, coupled to its networking, context,
  authentication, types, parser, and execution engine
  ([server integration](https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/Server.cpp),
  [handler source](https://github.com/ClickHouse/ClickHouse/tree/master/src/Server)).
  It is evidence that a C++ implementation is possible, not a reusable library.
- Go [`jackc/pgx/pgproto3`](https://pkg.go.dev/github.com/jackc/pgx/v5/pgproto3)
  provides low-level message codecs and test/mock primitives. It does not own
  the complete server lifecycle and would leave Pinba maintaining the state
  machine that `psql-wire` and Rust `pgwire` already implement.

## Recommendation

Adopt Rust `sunng87/pgwire` if adding Rust and a narrow integration boundary is
acceptable. It is the only candidate here that combines credible maintenance,
a permissive license, full server-side simple/extended-query flows, mature
authentication including SCRAM, TLS, cancellation, types, and structured
errors.

Before committing to the boundary, build a disposable compatibility spike—not
production architecture—covering `psql`, libpq, JDBC, startup/SSL, one simple
query, one parameterized extended query, a typed result with nulls, an error,
and cancellation. This tests the library and foreign-language boundary without
doing codebase design.

If a foreign-language component is prohibited, stop and revisit that constraint.
Do not adopt `euiko/pgwire`, and do not extract protocol code from a database or
pooler under the label of using a library.
