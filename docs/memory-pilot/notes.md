# Memory pilot — Rust audit + Zig port plan

Written 2026-04-30 while parser pilot is in flight (Codex first-pass).
Authoritative source for Week 3 Day 1 dispatch. Read before handing
`sqlite.rs` to Codex.

Scope per plan: `lib.rs` (27 KB), `sqlite.rs` (97 KB), `traits.rs` (40 b),
`backend.rs` (5.7 KB), `policy.rs` (6.2 KB), `audit.rs` (8.9 KB).
**Total in-scope: 4,216 lines / ~145 KB across 6 files.**

The canonical `Memory` trait lives in `rust/crates/zeroclaw-api/src/memory_traits.rs`;
`traits.rs` is a one-line re-export. The trait surface (12 methods, 6
required + 6 with defaults) is reproduced verbatim at the bottom of this
note.

## Top-level findings

### F1 — No clock injection, no id-generator injection (R9 confirmed required)

`chrono::Local::now().to_rfc3339()` is hardcoded inside the `Memory` trait
impls at:

- `sqlite.rs:286` — `get_or_compute_embedding` (cache `created_at`/`accessed_at`)
- `sqlite.rs:585` — `store` (memories `created_at`/`updated_at`)
- `sqlite.rs:1113` — `store_with_metadata` (same path, different overload)
- `audit.rs:87` — `log_audit` (audit row `timestamp`)
- `audit.rs:100` — `prune_older_than` (cutoff calculation)

`uuid::Uuid::new_v4().to_string()` is hardcoded at:

- `sqlite.rs:587` — `store` (`memories.id`)
- `sqlite.rs:1115` — `store_with_metadata`

Plus: **`Local::now()` uses local timezone, not UTC.** RFC3339 output
will include the local offset, so timestamps differ by host TZ. Existing
tests pass because they compare structure, not timestamp values
(`export_ordering_is_chronological` at line 2594 sleeps 10ms between
inserts and checks ordering, not absolute values).

This is exactly the R9 risk. Plan said "refactor Rust to do so before
porting if it doesn't already" — **it doesn't, and we have to.** Two
viable mitigations:

| Approach | Cost | Notes |
|---|---|---|
| **A. Refactor Rust trait to take `Clock` + `IdGen`** | High — touches the api crate, every Memory impl, every constructor | Cleanest; matches plan intent; lets us write deterministic tests both sides |
| **B. Normalize in eval driver** | Low — strip `id`, `created_at`, `updated_at`, `timestamp` before diff; accept any RFC3339 in `*_at`, any UUID v4 in `id` | Doesn't change either codebase; keeps fixtures byte-equal *modulo normalization* |

**Recommendation: B for the pilot, A as a deferred follow-up.** The
pilot's goal is parity on observable behavior, and these fields are
incidentally non-deterministic — they're not what the parser/recall logic
is testing. The `compare_normalized` step in `evals/driver/run_evals.py`
already does shape-based comparison; extend it for memory.

If we go with B, the Zig port can also use wall-clock + random UUIDs and
the eval driver will tolerate both. **This is the simplest path; flagged
as decision item D12 below.**

### F2 — Schema migrations use ALTER TABLE introspection, not `PRAGMA user_version`

The plan §"Pilot port: memory" said:

> `CREATE TABLE` statements copied **verbatim**; PRAGMA `user_version`
> numbers preserved so Zig and Rust can read each other's databases.

Reality (`sqlite.rs:160–237`): there is no `user_version` anywhere in the
crate. Schema evolves via `IF NOT EXISTS` table creation + four
introspection-guarded `ALTER TABLE` blocks (`session_id`, `namespace`,
`importance`, `superseded_by`). The introspection probe is:

```rust
let schema_sql: String = conn
    .prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name='memories'")?
    .query_row([], |row| row.get::<_, String>(0))?;
if !schema_sql.contains("session_id") { ... }
```

Implication: **the Zig port should match this introspection pattern, not
introduce `user_version`**. Adding `user_version` on the Zig side would
diverge the on-disk format (Rust would still read its own DBs fine, but a
Rust-written DB opened by Zig would have user_version=0 and trigger a
re-migration that's a no-op but cosmetically ugly).

**Decision item D13.** Zig matches Rust's introspection-driven migration.
Plan text needs an erratum.

### F3 — Rust uses bundled SQLite; macOS system SQLite is older (R13 active)

`Cargo.toml:18`: `rusqlite = { version = "0.37", features = ["bundled"] }`.
That ships its own SQLite C amalgamation (~3.46+ as of rusqlite 0.37);
the macOS system sqlite on this host is **3.43.2** (verified via
`sqlite3 --version`).

For the Zig side per D6 (system libsqlite3 via `@cImport`), this means
**Rust and Zig will run different SQLite versions on the same host.**
FTS5 BM25 ranking, tokenizer behavior, and edge cases around `MATCH`
queries can differ subtly between versions. Risk to byte-equal fixture
parity is non-zero.

Three options:

| Option | Cost | Result |
|---|---|---|
| **a. Drop "bundled" from rusqlite** | 1-line Cargo.toml change | Both sides use macOS system 3.43.2; consistent on Mac, may differ on Linux CI |
| **b. Zig links bundled SQLite amalgamation** | ~30 LOC build.zig + check in amalgamation | Both sides use the same pinned C source; portable |
| **c. Zig uses system, fixtures tolerate ranking diffs** | Eval driver complexity for FTS5 score normalization | Brittle |

**Recommendation: option (b)** — vendor the SQLite amalgamation under
`zig/vendor/sqlite3/`, build it as a static lib in `build.zig`, link
against it. Maintains D6's *spirit* (no Zig wrapper around SQLite, just
`@cImport`) while pinning the version. Update D6 to "system OR pinned
amalgamation, NOT system on one side and bundled on the other".

This is **decision item D14**. Worth deciding before Codex picks up
sqlite.rs.

### F4 — `tokio::task::spawn_blocking` wraps every storage op

Pattern at `sqlite.rs:583`, 593, etc.:

```rust
tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
    let conn = conn.lock();
    ...
}).await?
```

Plan §"Pilot port: memory" says: "Pilot uses **synchronous APIs only**.
Async wrappers (libxev thread pool) deferred until runtime port needs
them." That's correct — the Zig port skips this layer entirely. Each
spawn_blocking body is simple top-to-bottom SQLite work; just port the
body, drop the spawn_blocking wrapper, the Zig caller blocks on it.

**Implication for the Memory trait surface in Zig:** drop `async`. The
Zig `Memory` interface becomes a vtable struct over a tagged union with
synchronous functions. Matches D7 + the dispatcher pattern from the
parser pilot.

### F5 — Connection is `Arc<Mutex<Connection>>` from parking_lot

`sqlite.rs:29`. Single connection, mutex-protected. WAL mode + NORMAL
synchronous (PRAGMAs at `sqlite.rs:61–65, 107–112`). Concurrent writers
serialize on the mutex; concurrent readers in WAL mode work without it.

Zig translation: `std.Thread.Mutex` over `*c.sqlite3`. The pilot is
sync-only so `Arc` collapses to a plain `*Self`; if we ever need
shared-by-value, switch to `std.Thread.RwLock` plus refcount.

**Note for benchmark methodology:** the criterion benches run on a
single-threaded tokio runtime (verify in `rust/benches/agent_benchmarks.rs`),
so the Zig sync-blocking version is comparing apples-to-apples. If
criterion runs multi-threaded, we need to reproduce that or document the
divergence.

### F6 — Embedding pipeline is feature-gated by `embedder.dimensions() == 0`

`sqlite.rs:280–283`: `get_or_compute_embedding` short-circuits to `None`
when the configured embedder is the noop. The pilot can — and should —
ship with **only the noop embedder**, leaving the embedding cache table
empty, deferring the real embedding plumbing (HTTP to OpenAI/Ollama) to
the provider port.

**Concrete pilot scope:**
- Port: `SqliteMemory::new`, `init_schema`, `category_to_str`,
  `str_to_category`, `content_hash`, `connection`, the noop branch of
  `get_or_compute_embedding`, all `Memory` trait methods.
- Skip in Zig pilot: `with_embedder` (noop only), `fts5_search`,
  `vector_search`, `recall_by_time_only`, `reindex`. These are advanced
  retrieval that the criterion benches don't exercise.

The criterion bench IDs the Zig port must hit (per plan §"Acceptance
gates"): `memory_store_single`, `memory_recall_top10`, `memory_count`.
All three use the basic store/recall/count path — none of the advanced
retrieval. **The pilot Zig surface is small.**

### F7 — `audit.rs` writes to a *separate* SQLite DB

`audit.rs:48-76` opens its own `audit.db` next to the workspace dir;
`AuditedMemory<M>` is a decorator wrapping any `Memory` impl. The pilot
can choose:

- (i) Port `audit.rs` along with `sqlite.rs` (decorator pattern in Zig
  uses the vtable-struct sandwich — matches dispatcher).
- (ii) Defer audit to post-pilot.

The criterion benches don't exercise audit. **Recommendation: defer.**
Drops ~9 KB of port work and keeps the pilot focused on the trait
surface that benchmarks measure.

### F8 — `policy.rs` is pure, no I/O, easy port

198 lines, no `chrono`, no `uuid`, no SQL. Pure Rust → pure Zig
translation. Single subagent can do it in one shot. Include in pilot
since `Memory::store` calls into it (verify by grepping store
implementations — TODO before Codex dispatch).

### F9 — `backend.rs` is config/string-classification, trivial

185 lines, just `MemoryBackendKind` enum + helpers like
`classify_memory_backend("sqlite")`. The factory in `lib.rs:295+`
(`create_memory`) uses these to dispatch on the configured backend
string. Pilot needs only the SQLite case. **Port `backend.rs` only if
`lib.rs` factories are also being ported in this pilot** — otherwise
defer.

### F10 — `lib.rs` is mostly factory logic + autosave-key heuristics

Real porting work in `lib.rs` is small once feature gates collapse:

| In pilot | Why |
|---|---|
| `is_assistant_autosave_key` (163) | String-prefix check, used by Memory callers |
| `is_user_autosave_key` (172) | Ditto |
| `should_skip_autosave_content` (179) | Content filter |
| `create_memory` (295) → SQLite branch only | Constructor entry-point |

Skip everything postgres/markdown/lucid/none related. The
`resolve_embedding_config` (227) tree is provider-port territory.

## Schema (verbatim — Zig port copies this exactly)

From `sqlite.rs:161–203` plus the four migration ALTERs:

```sql
-- Connection PRAGMAs (sqlite.rs:61, also re-applied at 108)
PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;
PRAGMA mmap_size    = 8388608;
PRAGMA cache_size   = -2000;
PRAGMA temp_store   = MEMORY;

-- Core memories table
CREATE TABLE IF NOT EXISTS memories (
    id          TEXT PRIMARY KEY,
    key         TEXT NOT NULL UNIQUE,
    content     TEXT NOT NULL,
    category    TEXT NOT NULL DEFAULT 'core',
    embedding   BLOB,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_memories_category ON memories(category);
CREATE INDEX IF NOT EXISTS idx_memories_key ON memories(key);

-- FTS5 full-text search (BM25 scoring)
CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
    key, content, content=memories, content_rowid=rowid
);

-- FTS5 sync triggers
CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
    INSERT INTO memories_fts(rowid, key, content)
    VALUES (new.rowid, new.key, new.content);
END;
CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
    INSERT INTO memories_fts(memories_fts, rowid, key, content)
    VALUES ('delete', old.rowid, old.key, old.content);
END;
CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
    INSERT INTO memories_fts(memories_fts, rowid, key, content)
    VALUES ('delete', old.rowid, old.key, old.content);
    INSERT INTO memories_fts(rowid, key, content)
    VALUES (new.rowid, new.key, new.content);
END;

-- Embedding cache with LRU eviction
CREATE TABLE IF NOT EXISTS embedding_cache (
    content_hash TEXT PRIMARY KEY,
    embedding    BLOB NOT NULL,
    created_at   TEXT NOT NULL,
    accessed_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cache_accessed ON embedding_cache(accessed_at);

-- Migrations (run idempotently every open)
ALTER TABLE memories ADD COLUMN session_id TEXT;          -- guarded by !contains("session_id")
CREATE INDEX IF NOT EXISTS idx_memories_session ON memories(session_id);

ALTER TABLE memories ADD COLUMN namespace TEXT DEFAULT 'default';
CREATE INDEX IF NOT EXISTS idx_memories_namespace ON memories(namespace);

ALTER TABLE memories ADD COLUMN importance REAL DEFAULT 0.5;
ALTER TABLE memories ADD COLUMN superseded_by TEXT;
```

**FTS5 status:** macOS system sqlite 3.43.2 includes FTS5 (verified
locally with `CREATE VIRTUAL TABLE t USING fts5(x);`). Linux CI must
verify the Homebrew-pinned sqlite has it too (default builds do, but
explicit check needed in scripts/02-install-toolchains.sh).

## Memory trait surface (Zig port target)

From `rust/crates/zeroclaw-api/src/memory_traits.rs:112-258`. Trait is
`async`; Zig port drops async per F4.

Required (no default impl):
- `name() -> &str`
- `store(key, content, category, session_id) -> Result<()>`
- `recall(query, limit, session_id, since, until) -> Result<Vec<MemoryEntry>>`
- `get(key) -> Result<Option<MemoryEntry>>`
- `list(category, session_id) -> Result<Vec<MemoryEntry>>`
- `forget(key) -> Result<bool>`
- `count() -> Result<usize>`
- `health_check() -> bool`

Defaulted (impl can override):
- `purge_namespace(ns) -> Result<usize>` — default: error
- `purge_session(sid) -> Result<usize>` — default: error
- `store_procedural(messages, sid) -> Result<()>` — default: noop
- `recall_namespaced(ns, query, ...)` — default: recall+filter
- `export(filter)` — default: list+filter
- `store_with_metadata(key, content, cat, sid, ns, importance)` — default: store

Zig vtable struct (analog of dispatcher port pattern):

```zig
pub const Memory = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        name: *const fn (*anyopaque) [:0]const u8,
        store: *const fn (*anyopaque, allocator: std.mem.Allocator, key: []const u8, content: []const u8, category: MemoryCategory, session_id: ?[]const u8) MemoryError!void,
        recall: *const fn (...) MemoryError![]MemoryEntry,
        // ...
        deinit: *const fn (*anyopaque, std.mem.Allocator) void,
    };
    // ...wrappers...
};
```

`SqliteMemory` exposes `pub fn memory(self: *Self) Memory`.

## Eval-memory binary contract (Rust + Zig must match)

Need to write this from scratch — only `eval-parser.rs` exists today.
Both implementations read scenario JSONL from stdin, produce canonical
JSON to stdout.

**Scenario format (JSONL, one op per line):**

```
{"op":"open","path":"/tmp/eval-mem.db"}
{"op":"store","key":"k1","content":"hello","category":"core","session_id":null}
{"op":"store","key":"k2","content":"world","category":"core","session_id":"s1"}
{"op":"recall","query":"hello","limit":10,"session_id":null,"since":null,"until":null}
{"op":"count"}
{"op":"forget","key":"k1"}
{"op":"export","filter":{"namespace":null,"session_id":null,"category":null,"since":null,"until":null}}
{"op":"close"}
```

**Output format:** one JSON line per op that returns data, schema:

```json
{"op":"recall","result":[{"id":"<UUID>","key":"k1","content":"hello","category":"core","timestamp":"<RFC3339>","session_id":null,"score":null,"namespace":"default","importance":0.5,"superseded_by":null}]}
```

**Normalization (per F1 recommendation B):** the eval driver replaces
`<UUID>` with `"<UUID>"` and `<RFC3339>` with `"<TS>"` before byte-diff.
Order of recall results is preserved (BM25 ranking determines it; both
sides must rank identically — this is what F3 stresses).

## Open decisions to land before dispatching Codex

| ID | Decision | Default if no answer |
|---|---|---|
| **D12** | Clock/UUID determinism: refactor Rust trait (A) or normalize in eval driver (B)? | B — pilot ships with normalization |
| **D13** | Schema versioning: introspection (match Rust) or `user_version`? | Introspection — match Rust |
| **D14** | SQLite version: bundled both sides, system both sides, or split? | Vendor amalgamation in Zig + drop "bundled" from rusqlite |
| **D15** | Audit decorator: port now or defer? | Defer post-pilot |
| **D16** | `lib.rs` factory: port the SQLite-only branch, or skip the factory entirely and have callers `new()` directly? | Skip factory; pilot calls `SqliteMemory.new` directly |

When parser pilot lands, surface these as a numbered list in `docs/decisions.md`
and confirm before Codex picks up `sqlite.rs`.

## Codex dispatch prompt — staging notes

Same shape as the parser prompt. The Zig target tree:

```
zig/src/memory/
├── root.zig         # re-exports
├── types.zig        # MemoryEntry, MemoryCategory, ExportFilter, ProceduralMessage, MemoryError
├── traits.zig       # Memory vtable struct
├── sqlite/
│   ├── conn.zig     # open/close, PRAGMAs, sqlite3 c-import wrapper
│   ├── schema.zig   # init_schema + introspection migrations (D13)
│   ├── store.zig    # store, store_with_metadata
│   ├── recall.zig   # recall, recall_namespaced, recall-by-time helper
│   ├── crud.zig     # get, list, forget, count, purge_*, export
│   ├── helpers.zig  # category_to_str, str_to_category, content_hash
│   └── memory.zig   # impls Memory vtable, ties the rest together
└── policy.zig       # 1:1 from rust/policy.rs (F8)
```

Out of scope for the Codex dispatch: `audit.zig` (D15), `backend.zig`
(F9), the `lib.zig` factory (D16). Add these post-pilot.

The dispatch happens in Week 3 Day 1. Before then: land D12–D16 as ADRs.
