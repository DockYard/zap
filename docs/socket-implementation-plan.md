# Zap Socket Implementation Plan

**Status: PROPOSED (rev 4) — awaiting final approval.** This plan synthesizes four
parallel deep-research investigations (cross-language SOTA; kernel-integration
architecture; fork substrate/TLS/DNS inventory with five compile-and-run probes;
functional-fit Zap API design) into a single, staged, approval-ready program for a
fully-featured socket layer in Zap that is competitive with modern languages and native
to Zap's green-process / typed-mailbox / supervisor model. **No implementation has
begun.**

**Scope ratified (2026-07-12):** the first campaign covers **the full stack — every
phase below, including the v2 netpoller and both client *and* server TLS.** The one
remaining decision is the server-TLS *implementation approach* (§7.1).

**Rev 2 (2026-07-12): re-analysis deltas.** An adversarial re-review of rev 1 against
the four research reports and the runtime's own constraints found and fixed:

1. **A sequencing bug:** the socket token table (fourth kernel domain) was scheduled
   with the netpoller, but cross-process `send_move` handoff, stale-handle panics, and
   TLS-sessions-behind-the-same-handle all require it far earlier. It is now
   **foundational (S0)**.
2. **An internal contradiction:** the anti-checklist forbids `SO_RCVTIMEO` as a timeout
   mechanism (OTP documents it as unreliable) while v1 suggested it. Resolved: v1
   bounds every blocking leaf with **internal `poll(2)`-quantum loops**, never
   `SO_*TIMEO` (§6.1).
3. **The drain tension:** single-owner move-only handles mean *no other process can
   close a blocked acceptor's listener*. Graceful drain is redesigned around
   bounded-poll re-attach + kill + drop-list (§6.2).
4. **A dual-implementation smell:** rev 1 had Tier-2 active mode as a pure-Zap pump
   *and* "kernel-native delivery" in v2 — a forbidden parallel path. Resolved: the pump
   is the *only* semantic model; v2 changes how `recv` parks, nothing else; any kernel
   fast-path is a separately-adjudicated, measured optimization (§5, Decision A).
5. **Missing scope:** UDP/datagram and Unix-domain sockets had no phase (they are
   Tier-0 MUST); now **S2**. Framing helpers had no owner; now in S6. A hardening/
   benchmark/docs phase (the concurrency campaign's P7 analogue) was absent; now
   **S9**.
6. **Missing design points now specified:** gate-OFF (non-concurrent program) socket
   behavior; partial-send reporting on send failure (Erlang `RestData` lesson);
   `ip6_only` in options; `local_address`/`bind`/listener-close in the API;
   accepted-socket option inheritance; binary-safe `String` payload verification;
   `max_connections` load-shedding; lock-free introspection counters; a security-
   considerations section (§8); hermetic test strategy for TLS (§7.3); the deliberate
   per-call-timeout-vs-Go-deadline choice recorded (Decision E).
7. **A language-surface risk surfaced:** `Tls.upgrade(plaintext :: unique Socket)`
   assumes parameter-position uniqueness annotation, which may not exist yet (only
   `send_move` is special-cased today). Now OQ2 with a dynamic-enforcement floor.

*(Phase renumbering from rev 1: old S0→S0, S1→S1, new S2 (datagram/unix), old S2→S3,
S3→S4, S3b→S5, S4→S6, S5→S7, S6→S8, new S9.)*

**Rev 4 (2026-07-13): stream-transformation design ratified and under construction.**
Three deep-research investigations (BEAM indefinite streaming; typed-FP stream
libraries; direct-style/transducer designs) produced `docs/stream-design-research.md`
and a ratified design: **`Stage`** (a first-class transformation value with explicit,
linearly-threaded state — init-by-constructor/step/flush; the purified transducer /
Gatherers-with-linearity) with **`Stream`** lazy adapters over `Enumerable`
implemented on stages, **`Enum.reduce_while`**, and **`Framer` as `Stage` instances**.
These are **standalone pure-Zap stdlib work, implemented ahead of the socket campaign**
(in progress 2026-07-13, zero compiler changes) — the socket phases consume them.
Consequences for this plan: rev-3's D16 (lazy Stream adapters) is superseded by the
built design; S6 is reframed (`Framer` = `Stage` instances with the convergent
flush/leftover-error/max-frame contract; the active-mode pump accepts arbitrary
stages; `Stream.through_process` — the one explicit async boundary: supervised
producer + credit-bounded typed mailbox + zero-copy Blob moves + mandatory visible
overflow policy — joins the campaign at S6, where socket handoff and sendability
machinery exist); S8 transport flow control is refined to **byte-denominated credits
with dual pause/resume thresholds** (Pipelines' anti-cycling design) alongside
count-based message credits with batched regrant. Doctrine sharpened in §4.1:
**processes OWN indefinite connections; streams TRANSFORM within an owner.**

**Rev 3 (2026-07-12): streaming-fit amendments.** Prompted by the review question
"how do we stream socket data in Zap?": rev 2's streaming story was hand-written
recursion — correct, but Erlang's answer rather than Zap's, leaving the socket layer
outside the language's functional core. Codebase inspection found the integration
was already designed for: `Enumerable(element)` (`lib/enumerable.zap`) is a
pull-based iterator protocol whose `next/1` threads a `unique` state and whose
`dispose/1` exists precisely to "release any resources owned by an unconsumed
iteration state" — a resource-backed stream contract with **no resource-backed
implementor in the stdlib yet**. Sockets become the first. Changes: (1) new **§4.1
streaming model** — pull (Enumerable/`Enum`/`for`), push (Tier 2 credits), pipeline
(cross-process Blob moves) — with framing redesigned as a pure incremental scan;
(2) **S1** gains `Socket.chunks` (the Enumerable implementation) + `Socket.fold`;
(3) **S6** framing becomes a pure `Framer` value testable with zero I/O, feeding
`Socket.frames`; (4) **OQ2 downgraded** — `unique` parameter annotation already
exists and is pervasive in `Enum` (`lib/enum.zap`); (5) **D16** added (lazy `Stream`
adapters as future general stdlib work, deliberately not owned by this campaign).

**Lineage:** four research reports (2026-07-12) → rev 1 → this rev 2. It follows the
same research → plan → approval → phased-implementation-with-gap-loops discipline as
`docs/concurrency-implementation-plan.md` (now CAMPAIGN COMPLETE).

**Substrate basis:** fork at `~/projects/zig` (HEAD `df4a90ae04`, 0.16.0-based), Zap at
HEAD `87a0d9d`. All load-bearing substrate claims were proven by compile-and-run probes
on this machine (aarch64-macos), with cross-compile checks for
linux-gnu/musl/windows-gnu/wasm32-wasi.

---

## 0. Executive summary — the thesis

Zap sits at a **rare intersection**: it has *both* Go's green-thread-over-netpoller
runtime *and* Erlang's actor/mailbox/supervisor substrate. Almost no language has both.
The socket layer exploits both, layered — not picking one:

- **Tier 1 (primary, foundational):** a **value-threaded, synchronous-reading `Socket`
  handle** — `connect → send → recv → close` threads an immutable value and returns
  `Result(t, SocketError)`, never touching a mailbox. Go's `net.Conn` / Mint's
  connection-as-value ergonomics, but with Zap's immutability, exhaustive `case`, and a
  type-safe EOF. The runtime parks the fiber under the hood so blocking-style code
  scales — and, unlike Rust/tokio, **no split/ownership ceremony**: stackful fibers can
  serve the read and write sides of one connection without `into_split`.
- **Tier 2 (opt-in, pure Zap over Tier 1):** an **active-mode "socket as a typed
  message source"** — an owning process receives inbound data as **typed** mailbox
  messages it can `receive` alongside everything else, with credit-based backpressure
  (`{active, N}` semantics). Erlang's killer feature — but where Erlang delivers
  *untyped tagged tuples*, Zap delivers a *typed* message that pattern-matches natively.
  **No mainstream language has this.**
- **TLS (client and server) and higher protocols (HTTP, WebSockets, DB drivers)** ride
  the *same* `Socket` type — one abstraction; `http`-vs-`https` differs only at the
  connect/listen call.

**The de-risking headline:** the fork substrate is dramatically further along than
expected. TCP/UDP/Unix sockets, a pure-Zig DNS resolver with happy-eyeballs racing, and
a **working pure-Zig TLS 1.3 client with OS-trust-store verification** all exist and
were proven end-to-end. **The socket layer proper requires zero fork ABI changes** (the
server-TLS handshake and optional option-surface work are fork *contributions*, not ABI
changes).

---

## 1. What already exists (the assets that de-risk this)

### 1.1 Substrate (fork `std.Io.net`, all PROVEN by probe)

| Capability | State | Evidence |
|---|---|---|
| POSIX syscall floor (socket/bind/listen/accept/connect/send/recv/shutdown/socketpair/poll/setsockopt/fcntl) | **Proven runs** on aarch64-macos | probe1; `std.posix` + raw `std.posix.system.*` |
| `std.Io.net` high-level surface: `IpAddress`, `Socket` (UDP), `Stream` (TCP) with std Reader/Writer, `Server.accept`, `UnixAddress`, `shutdown` | **Proven runs**; cross-compiles all targets | probe2; `net.zig` (1484 lines), 15 net vtable ops `Io.zig:238-254` |
| `Reader.readVec` maps `n==0 → error.EndOfStream` | **Built** — the C `recv()==0` footgun already fixed at substrate | `net.zig` |
| Happy-eyeballs connection racing (`HostName.connect`/`connectMany`) | **Proven** — raced ::1+127.0.0.1, live `example.com` | probe3; `HostName.zig:274` |
| DNS: pure-Zig resolver (Linux), `DnsQueryEx` (Windows), `getaddrinfo`-on-pool (macOS) | **Proven** — 4 live A/AAAA records | probe3; `Threaded.zig:13465+` |
| Native connect timeout (`ConnectOptions.timeout: Io.Timeout`) + UDP `receiveTimeout` | **Built** | `net.zig:332`, `Io.zig:459` |
| **TLS 1.3 + 1.2 client, OS trust store, SNI, ALPN, PQ hybrid key shares** | **Proven end-to-end** — 157 macOS certs, TLS 1.3 handshake + chain/host verify, HTTP 200 decrypted; cross-compiles all targets | probe4; `std.crypto.tls` (758 ln) + `tls/Client.zig` (~2000 ln); `Certificate.Bundle.rescan` per-OS |
| kqueue readiness + **EVFILT_USER wake** (the E9-reserved poller primitive) | **Proven** | probe5; `std.Io.Kqueue` (1520 ln) |

Per-target availability (proven/cross-checked): macOS ✔, Linux ✔, Windows ✔ (NT AFD
ioctls, incl. Unix sockets), wasm32-wasi → `error.NetworkDown` (correctly gated). The
`:network` target capability already exists and is per-target-tested
(`src/target_caps.zig:84`, `:278`) — `lib/socket.zap` decls just take
`@available_on(:network)`.

### 1.2 Kernel assets (from the completed concurrency campaign)

| Capability | State | Evidence |
|---|---|---|
| Blocking-pool offload — run a syscall on the fiber's own stack into its own heap, free the core | **Built** | `blocking_pool.zig`, `Process.blocking` `abi.zig:2144` |
| Foreign-thread wake seam (a poller thread → a green process): `wake()`, `reviveIfParked` foreign-waker route, `pushWake` | **Built** ("Phase 4 admission seam") | `scheduler.zig:3217`, `:4950`, `:4896` |
| E9 poller wake-primitive reservation (`EVFILT_USER` / `MSG_RING`) | **Reserved by design** | `concurrency-bench-results.md:805`; `scheduler.zig:262` |
| Deadlock detector with closed-world producer inventory + standing 7.6 re-adjudication hook | **Built + hook** | `scheduler_pool.zig:551-624`; plan item 7.6 |
| Drop-list — external-resource destructors run on **every** teardown path (kill + normal exit) | **Built** (but `registerDropResource` not yet in `abi.zig`) | `process.zig:331-480`, run `scheduler.zig:4340` |
| Kernel-owned allocation-domain pattern (envelope pool, Blob domain) | **Built ×2** | `envelope_pool.zig`, `blob.zig` |
| Pid-like generational-token pattern | **Built** | `pid_table.zig:26-62` |
| Move-only cross-process ownership transfer (`send_move`, use-after-move = compile error) | **Built** | `lib/process.zap` |
| Introspection surface (for socket counters) | **Built** | `introspection.zig` |

**Net: the socket layer is mostly writing Zap (`lib/socket.zap`) over an existing,
proven substrate — plus the socket domain/table and one small ABI export at the
foundation, the server-TLS handshake as the security-critical net-new piece, and a
bounded kernel extension (netpoller + 7.6 legs) for v2.**

### 1.3 Per-target commitments (Windows and wasm, explicitly)

The socket layer inherits the concurrency campaign's adjudicated per-target posture
(P7-J3: **Windows gate-ON is unsupported in v1, rejected at the driver's OS capability
gate with the 7.2a port-list diagnostic; gate-OFF Windows works**). The commitments,
per target:

| Target | Gate-OFF sockets (Tier 1 + TLS, inline path — Decision D) | Gate-ON sockets (green processes, Tier 2, servers, pool/poller) |
|---|---|---|
| macOS aarch64/x86_64 | **Full, all phases** (primary dev target; probes ran here) | **Full, all phases** |
| Linux aarch64/x86_64 (gnu+musl) | **Full, all phases** (cross-compile verified; CI-runnable) | **Full, all phases** (S8 poller: epoll) |
| Windows x86_64 | **In scope.** Substrate proven: NT AFD ioctls (TCP/UDP + Unix sockets on Win10 RS4+), `DnsQueryEx` async DNS, TLS client cross-compiles. Delivered through Decision D's inline path — no kernel required. **Caveat:** run-level verification on Windows is a documented CI gap (no Wine on this host; compile-level verified), same as the concurrency campaign's posture. | **Out of scope — blocked on 7.2a**, the concurrency campaign's enumerated Windows kernel port (futex→`WaitOnAddress`, fiber context switch Win64 callconv + TEB stack bounds, mmap→`VirtualAlloc`, monotonic clock). This campaign does not expand 7.2a; the S8 IOCP poller leg **folds into 7.2a** as its I/O-integration piece (R4). The socket layer is designed so that when 7.2a lands, Windows gate-ON sockets need only the IOCP poller leg — no API or domain changes. |
| wasm32-wasi | **Deliberately none.** wasi preview1 has no socket API; the substrate returns `error.NetworkDown` and Zap rejects at **compile time** with the `:network` capability diagnostic (`@available_on(:network)` — the correct, verified behavior). | **Permanently out of scope under the current design** — stackful fibers are architecturally impossible on wasm (call stack inaccessible), independent of sockets. |

Two consequences made explicit: (1) **Windows users get real socket programs from this
campaign** — clients, scripts, an HTTPS client — just not green-process servers until
7.2a; the plan's phase exit gates include windows-gnu cross-compile checks so the
inline path never rots. (2) **wasm "support" means a clean, diagnosed compile-time
rejection**, never a silent failure — and if/when the Zig substrate gains WASI
preview2 `wasi-sockets`, gate-OFF socket support becomes possible there (tracked as
**D15**).

**What compiling socket code to wasm concretely does** (the existing gate machinery,
`src/types.zig:6093` — this exact behavior is the S0 exit-gate expectation): the
type-checker rejects at the call site, before any codegen —
`` `Socket.connect` is unavailable on `wasm32-wasi` `` with the label
`` this target lacks the `:network` capability `` and help text prescribing the
portable pattern: guard with a comptime `@target` branch (the gated reference in the
false branch is never instantiated, so one source file serves all targets) or build
for a `:network` target. The diagnostic is the dedicated `target_capability` domain
(never collapses into "cannot find / did-you-mean") and carries machine data
(`missing_capability`, `target`) for CI/LSP. Programs that don't reference gated
socket decls compile and run on wasi unaffected. Defense in depth: the substrate
itself returns `error.NetworkDown` on wasi, but Zap code cannot reach it — the
compile gate fires first.

---

## 2. The foundational decisions

### Decision A — Connection model: **two tiers, Tier 1 primary; the pump is the only active-mode implementation**

- **Tier 1 — value-threaded synchronous `Socket` handle (the primitive the runtime
  owns).** Necessary and the 90% path. Reads functional-first; needs no process or
  mailbox; backpressure is *automatic* because a blocking `send` parks the writing
  fiber until the OS accepts the bytes (Zap's structural answer to Erlang's
  `{active,true}` flood and asyncio's unbounded-buffer bug).
- **Tier 2 — active-mode typed-message source: a pure-Zap pump process over Tier 1,
  and nothing else.** The pump loops Tier-1 `recv` and forwards typed event envelopes
  to an owner's mailbox honoring a credit window — the same architectural move as
  `Supervisor` being pure Zap over the signal primitives. **This is the only
  implementation in the plan.** When the netpoller lands (S8), the pump's `recv`
  parks on the poller instead of a pool thread — the pump gets cheap *without
  changing*, because v2 swaps the suspension substrate underneath Tier 1, not the
  Tier-2 semantics. A kernel fast-path that bypasses the pump (poller pushes envelopes
  directly) is **not** in this plan: it would be a second implementation of the same
  semantics (forbidden as a fallback/parallel path) and it moves policy into the
  kernel against the prime directive. If profiling after S8 shows the pump hop is a
  real bottleneck, that optimization gets its own adjudication with measurements —
  not a default.

Rejected alternatives (with reasons): **Tier-1-only** cannot express selective receive
across many sockets + other messages in one mailbox. **Tier-2-only** (every socket an
owning process, Erlang `{active,true}` default) imposes no-backpressure flooding and an
extra process/hop on the common request/response case — and a payload-bearing union
message is unsendable today (§7.4).

### Decision B — Ownership model: **move-only, pid-like generational handle in a fourth kernel-owned domain — built at the foundation**

Isolation (share-nothing heaps, copy message passing) *forces* the model. An fd is
neither immutable nor safely copyable-by-value, so:

- A `Socket` is a **one-word generational token** (`zap_socket_handle :: u64`, a
  reserved field the runtime recognizes at process boundaries), backed by kernel-owned
  socket state in a **fourth allocation domain** (pattern: `blob.zig` +
  `pid_table.zig`): a socket table mapping handle → `{fd, owner, generation, kind
  (plain | tls-session), state}`. A process's per-spawn manager never sees a socket
  byte — teardown, the copy walker, and per-spawn managers are untouched.
- **The table is foundational (S0), not a netpoller deliverable.** Everything early
  needs it: stale-handle panics (S1), cross-process `send_move` re-parenting (S3),
  TLS sessions behind the same handle type (S4/S5). What S8 adds to the domain is
  only the fd-interest registry.
- **Unlike `Blob`** (deeply immutable, atomic-refcount *shareable*), a `Socket` is
  **single-owner and move-only**: it travels between processes solely via
  `Process.send_move` (consumes it; use-after-move is a compile error; a plain
  copy-`send` of a live socket is rejected). Two processes reading one fd is a data
  race the type system must forbid. Misuse of a stale handle **panics loudly and never
  corrupts memory** (generation-validated, the Blob discipline).
- **Crash-safe fd lifetime rides the drop-list:** a socket handle registers a
  `close`-the-fd destructor at open time; the runtime runs it on *every* exit path
  (normal and crash), so a crashing handler leaks no fd. Ownership transfer re-parents
  the ledger entry; a token for a socket whose owner-generation moved on dead-letters —
  exactly like a stale pid.
- **`controlling_process`-equivalent handover is owner-executed** (the ledger is an
  owner-only field): the current owner `send_move`s the token to the new owner, which
  adopts it into its own ledger on receipt (mirrors adopted-Blob receive).

### Decision C — Substrate reuse: **`std.Io.net` types + syscall wrappers; std TLS; zero fork ABI changes**

- Reuse `std.Io.net`'s `IpAddress`/`UnixAddress`/`Socket`/`Stream`/`Server` types, the
  DNS machinery, and happy-eyeballs `connectMany`. Go through the **portable
  `std.Io.net` API** (which the portability gate requires — raw `std.posix.`/`std.c.`
  calls outside the `runtime_os` seam fail the build), gaining the Windows AFD + wasi
  gating for free. Socket options not covered by `ListenOptions`/`ConnectOptions`
  (`TCP_NODELAY`, keepalive tuning, linger, `SO_REUSEPORT`, `ip6_only` at
  connect-time) are applied via the `runtime_os` seam over the present `setsockopt`
  wrapper — or, if cleaner, a **sanctioned fork contribution** extending
  `std.Io.net`'s option surface (decide at S0; R3).
- The primitive-addition path is the **existing** `:zig.Socket.*` → `runtime.zig`
  Socket namespace bridge, registered as module `zap_runtime` via the already-present
  `zir_compilation_add_struct_source` C-ABI call. **No new `zir_api` exports.**
- The kernel deliberately owns parking and does **not** implement the `std.Io` vtable,
  so the `Io.Evented`/`operate`/`Batch` event loop is *not* used. **v1** uses
  `std.Io.net` operations through the blocking-inline `Io.Threaded` singleton, each
  op offloaded per Decision D; **v2** has the kernel provide its own poller that reads
  fds on-core into the owning process's heap.

### Decision D — Gate-OFF programs get sockets too (offload-iff-kernel-live)

A plain Zap script (no `spawn`, concurrency gate OFF) must still be able to
`Socket.connect` — an HTTP-client script must not require spawning processes.
`Process.*` is a compile error gate-OFF, so `lib/socket.zap` cannot wrap ops in
`Process.blocking`. Instead the **runtime socket primitives internally offload iff the
concurrency kernel is live**: gate-ON → blocking-pool offload (v1) / poller park (v2);
gate-OFF → plain inline blocking on the single OS thread — semantically correct for a
single-threaded program (exactly how console IO behaves today). One Zap surface, one
primitive, a single runtime branch at the seam. This is not a dual backend: the
*semantics* are identical (a blocking call that returns the same results); only the
parking substrate differs, which is already true between v1 and v2. Gate-OFF
byte-identity applies to programs that don't use sockets; socket-using gate-OFF
programs link the socket runtime but no kernel.

### Decision E — Timeout model: **per-call relative timeouts (Erlang `gen_tcp` style), deliberately not Go deadlines**

Tier 1's ops take `timeout_ms` parameters (`recv(sock, n, timeout_ms)`,
`connect_timeout_ms` in options). Go's absolute per-handle deadlines were considered
and rejected for the primary surface: they are stateful on the handle (awkward on an
immutable value-threaded API), and Zap's Tier 2 already provides the composable
"bound a whole exchange" form via `receive … after` on active-mode events. One model
per tier, consistently: parameters in Tier 1, `after` in Tier 2. Timeouts are
implemented by the runtime/scheduler (poll-quantum in v1, timer+poller in v2) — never
`SO_RCVTIMEO`/`SO_SNDTIMEO` (§6.1). A timeout does **not** close the socket (Erlang
semantics; the socket stays usable).

---

## 3. The competitive acceptance bar (the feature matrix = the "done" definition)

From the cross-language SOTA report. This is the bar the campaign builds toward.

**Tier 0 — MUST (Erlang/Go parity floor; the definition of "not a toy"):**
TCP/UDP/Unix-domain (stream + dgram); IPv4/IPv6 with explicit `ip6_only` control;
connect with timeout + **happy-eyeballs by default**; listen (documented backlog +
somaxconn-cap semantics) + accept safe from many green processes; `close` vs
`shutdown(read|write|both)` with correct half-close (handle stays valid after
`shutdown(:write)` for the graceful handshake); passive `recv(length, timeout)` parking
the fiber; `send` with automatic backpressure **and bytes-written reporting on
failure**; **explicit EOF as a distinct variant**; `recv_exact`/`send_all` helpers;
cancellation of blocked accept/read/connect; curated portable options (nodelay,
keepalive, linger incl. explicit RST-close, reuseaddr, reuseport, buffer sizes,
ip6_only); **TLS client**; automatic fd hygiene (CLOEXEC + nonblock); binary-safe
payloads (arbitrary bytes, NUL, invalid UTF-8).

**Tier 1 — SHOULD (the difference between a toy and a real stack):**
`{active, once}`/`{active, N}` **typed-message** delivery with typed passive-transition
notification (the flagship differentiator); owner-lifetime cleanup +
`controlling_process` handover; **TLS server**; `SO_REUSEPORT` acceptor scaling;
vectored I/O (substrate has it); framing helpers (length-prefix / line, with a
`packet_size` DoS cap); native get/setopt escape hatch; connected UDP;
`max_connections` + graceful drain patterns; lock-free introspection counters.

**Tier 2 — COULD / documented non-goals initially:**
raw sockets, SCTP, OOB/urgent data (universally vestigial), multicast/broadcast,
FD-passing over `SCM_RIGHTS`, `TCP_FASTOPEN`, MPTCP, `TCP_QUICKACK`, zero-copy
`sendfile` (substrate `netWriteFile` exists; wire on a real use case), io_uring
backend, DNS SRV/TXT/MX + TCP-fallback, TLS cert hot-rotation.

**Anti-checklist (hard constraints baked into the design):** no uncapped
`{active,true}` firehose (credits only); async accept is a **documented first-class
primitive** from day one (Erlang's folklore `prim_inet:async_accept` broke on
migration); timeouts belong to the runtime, **never `SO_RCVTIMEO`/`SO_SNDTIMEO`** (OTP
documents them as unreliable under nonblocking implementations); ship **one** backend
per stage (OTP's dual-backend drift was years of pain); blocking-park accept for
kernel-FIFO fairness (epoll-on-shared-listener is "fundamentally broken");
`TCP_NODELAY` default **on** (dodges the 40 ms Nagle×delayed-ACK stall; Go's choice);
EOF and errors impossible to ignore by type; resource lifetime = owner lifetime;
no hidden unbounded send buffering (inet-driver lesson) and no silent partial-send
loss (socket-backend lesson).

---

## 4. The API surface (shape at a glance; full `@doc`'d signatures in the design report)

- **`lib/socket.zap`** — `Socket` handle + `connect/2,3`, `connect_to/2`, `listen/2`,
  `accept/1`, `send/2` (all-or-error, reports bytes-written on failure), `send_some/2`
  (explicit partial), `recv/1,2,3`, `recv_blob/3`, `chunks/2` + `fold/4` (streaming —
  §4.1), `shutdown/2`, `close/1`, `peer_address/1`, `local_address/1`. Every op
  `@available_on(:network)`.
- **`lib/socket/listener.zap`** — `Socket.Listener`, a **distinct type** (can't
  `send`/`recv` on a listener; can't `accept` a data socket — compile errors), with
  `close/1`. Accepted sockets **inherit the listener's options** (Ranch lesson).
- **`lib/socket/datagram.zap`** — `Socket.Datagram` (UDP + Unix-dgram), a distinct
  type with message-boundary semantics: `bind/2`, `send_to/3`, `recv_from/2,3`
  (returns payload + sender address; **truncation surfaced explicitly**, never
  silent), `connect/2` (connected-UDP peer filtering + plain `send`/`recv`),
  `close/1`. No EOF concept (datagrams have no stream close) — its result union
  differs from `Socket.Recv` accordingly.
- **`lib/socket/error.zap`** — `SocketError` as a `pub error` (`@code Z1101`),
  carrying a matchable `reason :: Atom` from an **open** POSIX/`getaddrinfo`-modeled
  set (`:econnrefused`, `:etimedout`/`:timeout`, `:econnreset`, `:closed`,
  `:nxdomain`, `:ehostunreach`, `:eaddrinuse`, `:emfile`, …; unmatched errno surfaces
  as its own atom), plus a `bytes_sent :: i64` field populated on send failures (the
  Erlang `{timeout, RestData}` lesson, adapted: the caller knows how much of the
  payload committed before the failure). Errors are `Result(t, SocketError)` —
  composing through `?`, `with`, `~>`, `rescue`, and `zap explain Z1101`.
- **`lib/socket/recv.zap`** — the EOF-safe union:
  ```
  pub union Socket.Recv { Chunk :: String, Closed, Failed :: SocketError }
  ```
  `Chunk` always carries ≥1 byte; `Closed` is EOF as a distinct constructor an
  exhaustive `case` *must* match. (`Socket.RecvBlob` is the `Blob`-carrying analogue
  for zero-copy large-body forwarding; `String` sends at/above the 64 KiB promotion
  threshold auto-promote to the Blob tier anyway.)
- **`lib/socket/address.zap`** — `Socket.Address` (sendable struct:
  `family`/`host`/`port`) with `ip4/2`, `ip6/2`, `unix/1`, `resolve/2`. DNS lives
  *inside* `Socket.connect(host, port)` by default; `resolve` + `connect_to` is the
  explicit escape hatch.
- **`lib/socket/options.zap`** — `Socket.Options`, a struct-with-typed-defaults:
  `nodelay = true`, `keepalive = false`, `reuse_address = true`, `reuse_port = false`,
  `ip6_only` (explicit — the cross-OS default divergence is a known portability
  hazard), send/recv buffer sizes, `backlog = 128` (with documented somaxconn-cap
  semantics), `connect_timeout_ms`, `linger_ms` (incl. the explicit RST-close
  affordance). A native get/setopt escape hatch (level + option + bytes) rides
  alongside for completeness.
- **`lib/socket/active.zap`** — Tier 2 `Socket.Active` (pump process + `Socket.Event`
  envelope + credit grants). See §7.4.
- **`lib/tls.zap`** — `Tls.connect/3` (returns a `Socket`), `Tls.upgrade/3` (STARTTLS;
  consumes the plaintext handle so no read-around-encryption path can exist), and
  (S5) `Tls.listen`/`Tls.accept` for the server side. Same `Socket` type everywhere —
  HTTP needs no `http`/`https` branching below connect. *(Naming note: resolve
  `Tls` vs `TLS` against house acronym style — `IO` is caps — at S4.)*

**Server pattern** (Go/Erlang shape in Zap idioms): a supervised acceptor process
`listen`s once, loops `accept`, and `send_move`s each connection to a fresh
per-connection handler that owns it. A crashing handler takes down only its own
connection; the drop-list closes its fd even on crash. Drop-in upgrade to a
`:simple_one_for_one` connection supervisor for auto-restart, plus `max_connections`
load-shedding and graceful drain (§6.2).

### 4.1 The streaming model — three composable forms

Streaming is where the socket layer must prove it belongs to a functional language
with BEAM-class concurrency, not merely expose syscalls. The plan provides three
forms, each leaning on machinery Zap already ships — no new abstraction is invented:

**Form 1 — pull streaming: sockets join the `Enumerable` core (the functional
default).** `lib/enumerable.zap` defines a pull-based iterator protocol —
`next(state :: unique Enumerable(element))` yields `{:cont, value, next_state}` /
`{:done, …}`, and `dispose/1` exists, per its own doc, to "release any resources
owned by an unconsumed iteration state." That is a socket-stream contract, verbatim —
and today the stdlib has **no resource-backed implementor** (File reads whole files).
Sockets become the first, and the proof of that protocol design:

- `Socket.chunks(socket, timeout_ms)` returns a stream value implementing
  `Enumerable(Result(String, SocketError))`: each `next` is a parking `recv` pull —
  **backpressure is inherent because nothing is read until demanded**; clean EOF is
  `:done`; a mid-stream failure yields one final `Error` element, then `:done`.
  Early exit through *any* `Enum` consumer (`take`, `find`, `any?`) calls `dispose`,
  releasing the iteration state deterministically.
- Every existing `Enum` HOF and `for` comprehension works on a live TCP stream
  unchanged — sockets compose with the language's functional core rather than
  growing a parallel API:

  ```zap
  # Fold a live stream (the fiber parks between chunks; the core runs other work):
  total = Enum.reduce(Socket.chunks(socket, 5000), 0, fn accumulated, chunk ->
    case chunk {
      Result.Ok(bytes)    -> accumulated + String.byte_size(bytes)
      Result.Error(_error) -> accumulated
    }
  end)

  # Take exactly four chunks, then dispose releases the iteration state:
  first_chunks = Enum.take(Socket.chunks(socket, 5000), 4)
  ```
- `Socket.fold(socket, initial, timeout_ms, callback)` is the ergonomic direct form —
  typed early-halt, overall `Result(accumulator, SocketError)` — for consumers that
  want the fold without threading `Result` elements. It is **thin sugar over
  `chunks` + `Enum.reduce_while`**, where `Enum.reduce_while` (an early-halt fold,
  `callback -> {:cont, acc} | {:halt, acc}`) is a **general `Enum` addition this
  campaign contributes** — the combinator belongs to the collections library, not to
  sockets (Zap-first layering; Elixir grew `reduce_while` for exactly this).
- **The send side needs no new machinery — the symmetry is free:** any `Enumerable`
  is an upload source via `Enum.each(chunks, fn bytes -> Socket.send(socket, bytes)
  end)`, and blocking `send` makes backpressure automatic *end-to-end*: a slow peer
  throttles the fold, which throttles the pull from the source.

**Form 1 boundedness — what terminates a live stream, stated precisely.** A
`Socket.chunks` stream ends (`:done`) on: clean EOF; a mid-stream failure (final
`Error` element); or a **pull timeout** — `timeout_ms` bounds each pull, so an *idle*
connection ends the stream with `Error(:timeout)` while **the socket itself stays
open and usable** (the stream *borrows* the socket; `dispose` releases only iterator
state, never closes the fd; a new `chunks` value resumes where the last left off).
What the timeout does NOT bound: a *chatty* long-lived connection — traffic keeps
arriving, so `Enum.reduce` keeps folding. Three consequences the docs state loudly:

1. **`Enum.reduce` on a live stream terminates on EOF / error / idle-timeout /
   caller-bounded consumption — otherwise it folds indefinitely** (constant memory —
   `reduce` materializes nothing — but it never returns and, critically, a fiber
   inside a fold is **deaf to its mailbox**). Use `take`/`find`/`any?`
   (short-circuit + dispose), `Socket.fold`/`Enum.reduce_while` (halt on your own
   protocol condition: byte count, frame count, terminator seen), or Form 2.
2. **The eager materializers are unsafe on unbounded streams:** `map`, `filter`,
   `flat_map`, `to_list`, `sort`, `reverse`, `uniq`, `count` all run to `:done`
   and/or accumulate the whole stream — on a socket that never closes, that is an
   OOM or a never-returns. The safe-on-live-streams set (`reduce`/`reduce_while`/
   `each`/`take`/`find`/`any?`/`all?`/`first`) vs the bounded-streams-only set is a
   **mandatory `@doc` + guide table** (S9). Lazy adapters that would make the
   materializers stream-safe are D16, deliberately general stdlib work.
3. **Form selection is by connection lifetime:** Form 1 is for *bounded transfers*
   (request/response, an HTTP body, a file transfer, "read until EOF") and
   predicate-bounded scans. A **long-running open socket** — a persistent
   connection, a subscription feed — is not a fold that returns; it is a *server
   loop*, and its home is **Form 2** (the active-mode `receive` loop, which also
   multiplexes control messages, other sockets, and idle timeouts — everything an
   infinite fold cannot observe) or **Form 3** (pipeline stages that intentionally
   run forever under supervision, terminated by socket close, crash, or supervisor
   shutdown — never by the fold "finishing"). Rev-4 doctrine, from the streaming
   research (`docs/stream-design-research.md`): **processes OWN indefinite
   connections; streams TRANSFORM within an owner** — and because transformations
   are `Stage` values, the same `dedupe`/window/framer logic is written once and
   runs in all three forms without reimplementation.

**Form 2 — push streaming: Tier 2 active mode (the actor form).** Typed
`Socket.Event`s delivered into the owner's mailbox under `{active, N}` credits;
consumed with `receive … after`; multiplexes many sockets + control messages + idle
timeouts in one process. **The credit grant IS the demand signal** — Zap's structural
equivalent of GenStage demand, at the primitive layer.

**Form 3 — pipeline streaming: cross-process composition (the concurrency form).**
Chunks read as `Blob`s (`recv_blob`) and `send_move`d through a supervised pipeline
of processes — each stage owns its heap, crashes in isolation, restarts under its
supervisor; payloads move zero-copy (one-word handle + atomic bump). The BEAM
streaming topology, with Zap's ownership guarantees.

**Framing composes with all three (S6, redesigned as a pure scan).** A `Framer` is an
immutable value with a pure incremental step — `{frames, framer} =
Framer.push(framer, bytes)` — bytes in, whole frames out, remainder carried in the
returned state. Pure means Zest-testable with **zero I/O** (split-across-chunks,
pathological fragmentation, cap-violation cases all run without a socket), and usable
identically under Form 1 (`Socket.frames(socket, framer)` — an Enumerable of whole
frames), Form 2 (the pump runs the framer and delivers frame events), and Form 3 (a
framer stage in a pipeline is a pure fold). The mandatory `packet_size` cap (§8) is
enforced inside the framer.

---

## 5. Staged architecture: v1 (blocking-pool) → v2 (netpoller)

The two stages share the socket domain/table, the `runtime_os` syscall seam, the
`lib/socket.zap` surface, and the drop-list crash-safety — **v1 is not throwaway; it
is the substrate v2 swaps the parking mechanism under.** The Zap-visible semantics do
not change between stages.

### Stage v1 — sockets on the blocking pool (small kernel delta, ships real programs)

- Each blocking op (`connect`/`accept`/`recv`/`send`/DNS) offloads per Decision D:
  gate-ON → `Process.blocking`-equivalent offload (runs the syscall on the fiber's own
  stack into its own heap, frees the core, re-attaches on completion — **zero new
  scheduling code**); gate-OFF → inline.
- **Bounded leaves via poll-quantum loops (never `SO_*TIMEO`).** The blocking pool
  quiesces at shutdown (waits for every in-flight op), and a kill during a blocking op
  defers to re-attach. Every v1 blocking leaf therefore runs as a **`poll(2)`-with-
  timeout loop with a bounded quantum (~100 ms)**: each quantum expiry re-attaches
  briefly, giving (a) prompt shutdown-quiesce, (b) prompt kill delivery, (c) user
  `timeout_ms` enforcement — all from one mechanism, with zero reliance on the
  documented-unreliable `SO_RCVTIMEO`. Idle connections cost a pool-thread wakeup per
  quantum — acceptable at v1's connection counts, eliminated entirely by v2.
- **Kernel/ABI deltas (small):** (a) the socket domain/table (foundational — Decision
  B); (b) export `zap_proc_register_drop_resource` in `abi.zig` + the socket-fd
  `close` destructor; (c) plumb `BlockingPool.Options.max_thread_count` so the hard
  64-thread cap becomes a runtime knob (`scheduler_pool.zig:227` currently passes
  `.{}`).
- **Honest ceiling:** the pool is 64 threads by default, *shared with GC and all FFI*,
  one parked thread per blocked connection, head-of-line blocking past the cap. v1 is
  correct and shippable for **a handful of listeners + tens of concurrent
  connections** — right for real socket programs and an HTTP client, wrong for a C10K
  server. Stated in the docs, not hidden; resolved by S8.
- **v1 happy-eyeballs caveat (OQ3):** true connection *racing* needs concurrency
  inside the connect leaf; through the blocking-inline singleton it may degrade to
  sequential-with-per-address-timeout. Decide at S0: accept sequential fallback for
  v1 (still correct, RFC-compliant ordering, bounded) with true racing arriving via
  the poller in v2, or run the connect leaf on a dedicated small `Io.Threaded`
  instance. Either way the *API* (`connect` races by default) is unchanged.

### Stage v2 — the netpoller (the scalable server story)

- One dedicated poller thread owns kqueue(macOS)/epoll(Linux)/IOCP(Windows), woken for
  control-plane changes via the **E9-reserved `EVFILT_USER`/`MSG_RING`**. A green
  process doing `recv` on a not-ready socket registers fd-interest, enters a new
  `.io_wait` state (parallel to `.blocking`), and yields — freeing the core **without
  consuming a pool thread**. On readiness the poller `pushWake`s the owning core;
  **data is read on-core into the process's own heap** — zero new payload atomics,
  invariant intact. One poller thread serves *thousands* of connections.
- Timeouts move from poll-quanta to the timing wheel + poller (no more periodic
  wakeups for idle connections); cancellation of a parked op becomes interest
  deregistration (the drop-list destructor deregisters interest on crash).
- Net-new kernel work: the poller thread + fd-interest registry (keyed on pid
  generation so a fired interest for a dead process is discarded like a stale timer);
  the `.io_wait` state + yield reason; the fd-interest → `pushWake` bridge; **and the
  7.6 re-adjudication (§5.1)**. The Tier-2 pump is untouched (Decision A).

### 5.1 THE load-bearing piece — the 7.6 deadlock-bracket re-adjudication for the poller

The deadlock detector's no-false-positive proof stands on a **closed-world producer
inventory**: any *new* wake source must re-adjudicate the bracket, and the invariant
note names "an I/O poller thread parking in kqueue/io_uring" explicitly. The kernel
research established that this needs **no proof rewrite** — the poller adds **two
legs**, each copying an existing template:

1. **Armed-interest leg (the armed-timer template).** A process parked on a
   maybe-readable fd is morally identical to a `receive…after` waiter with an armed
   timer — a packet is the moral equivalent of a timer fire. Mirror
   `if (core.armedTimerCount() != 0) return;` with
   `if (poller.armedInterestCount() != 0) return;`. A system of live processes all
   parked on readable-eventually sockets is **not** deadlocked (sound against a
   truly-hung network — a dead peer is indistinguishable from a slow one; Go/BEAM
   don't call that deadlock either; an optional idle-timeout on interests converts it
   to the timer case).
2. **In-flight-completion leg (the blocking-pool source-idle template).** The
   dangerous window is readiness-fired-but-not-yet-`pushWake`'d (record "in hand",
   invisible to a queue scan) — identical to the blocking pool's in-flight window.
   Mirror `if (!blocking_pool.isIdleApprox()) return;` with
   `if (!poller.isIdleApprox()) return;`, keeping
   `{armed_interest_count, inflight_completion_count}` under one poller lock.

**The load-bearing ordering discipline (get this right and it's just legs-extended, no
new seqlock):** the readiness→wake **publish must be ordered before** the `inflight`
decrement, and the interest-arm **before** the process's `idle_count`-visible
transition to `.io_wait` — the same "every publisher ordered before that core's
seq_cst `idle_count` increment" discipline the proof already relies on. The poller
needs *both* legs (the blocking pool needs only the in-flight one) because its process
is *passively parked* with no running thread, so the armed-interest leg covers the
idle-but-live window the in-flight leg cannot.

---

## 6. Two design tensions rev 2 resolves

### 6.1 Bounded ops without `SO_RCVTIMEO`

Rev 1 mandated bounded v1 reads "via `SO_RCVTIMEO` or poll" while the anti-checklist
forbids `SO_*TIMEO` — OTP explicitly refuses it ("unknown if and how this option
works… may cause malfunctions" under a nonblocking implementation). Resolved: **all
v1 bounding is `poll(2)`-with-timeout quanta** (proven present in probe 1), a single
mechanism that simultaneously provides user timeouts, shutdown-quiesce, and
kill-responsiveness (§5, v1). `SO_RCVTIMEO` never appears, in the implementation or
the surface.

### 6.2 Graceful drain under single-owner handles (the listener-close question)

Thousand Island's drain pattern — *another* process closes the listen socket, blocked
accepts abort, existing connections finish within `shutdown_timeout` — assumes
cross-process socket access, which Decision B forbids (single-owner, owner-only
ledger). Zap's drain is therefore built from what the model gives:

- **The acceptor is mailbox-responsive by construction:** v1's poll-quantum re-attach
  (and v2's poller park alongside mailbox wakes) means a blocked `accept` observes a
  drain message or a kill within a bounded quantum. Drain = send the acceptor a stop
  message (or kill it); the acceptor (or its drop-list, on kill) closes the listener;
  pending accepts abort with `:closed`.
- **Already-accepted handlers keep draining:** they own their connections
  independently; the connection supervisor applies a `shutdown_timeout` and then
  kills stragglers, whose drop-lists close their fds. No fd leaks on any path.
- The substrate independently documents `shutdown`-cancels-blocked-`accept` for the
  *owner's own* concurrent use; cross-process close is never needed.

This is codified as the S3 drain deliverable and exit gate.

---

## 7. TLS, DNS, and the sendability caveat

### 7.1 TLS scope

- **Client TLS: in scope (S4).** `std.crypto.tls.Client` is proven end-to-end (TLS
  1.3, OS trust store, SNI, ALPN, hostname + chain verification), zero FFI, zero
  build-system dependency, cross-compiles all targets. It rides the *same* `Socket`
  type (`Tls.connect` returns a `Socket`; the session state lives behind the handle in
  the socket domain — Decision B). No renegotiation (deliberate security posture —
  rustls model). Verification is **on by default**; disabling it is a loud, explicit
  option. **Low risk — the client path is settled.** One known integration gotcha
  (probe 4): the TLS writer's flush must also flush the underlying stream writer.
- **Server TLS: in scope (S5) — implementation approach is the open decision.** std is
  *client-only*: it ships the record layer, cipher suites (TLS 1.3 AEADs + TLS 1.2
  ECDHE + PQ hybrid key shares), and key schedule, but **no server-side handshake
  state machine** (ClientHello parse → cert/key selection → key exchange → Finished).
  Two production-grade paths:
  - **(a) Pure-Zig on std's record layer** — write the server handshake in the fork
    atop the existing record layer + crypto primitives (an upstreamable
    `std.crypto.tls.Server`). *Pros:* zero FFI, single static binary, clean
    cross-compile everywhere, consistent with the std client and Zap's no-dependency
    ethos. *Cons:* a large, security-critical implementation (server handshake,
    cert-chain serving, session tickets/resumption, ALPN selection) that must be
    hardened to a high bar.
  - **(b) Vetted C binding (BoringSSL, or rustls-ffi)** — bind an audited library for
    the *server* path only. *Pros:* battle-tested handshake + side-channel hardening.
    *Cons:* a C/native build dependency cutting against the single-binary /
    clean-cross-compile posture, per-target link/bundle burden. **OpenSSL is not a
    candidate.**
  - **Recommendation: path (a)**, preserving the zero-FFI / single-binary /
    all-target invariant — accepting the larger, more careful build as exactly the
    "correctness over cost" trade the project mandates. Scope discipline for v1 of
    the server: TLS 1.3 only (no 1.2 server), no renegotiation, no client-cert auth
    initially (deferred), session tickets optional-off by default. Path (b) is the
    fallback *only* if a record-layer gap proves genuinely infeasible to close at
    quality. **This is the one decision still open (OQ0).**
- **Cert/key loading** from PEM at listen-time is in scope; **hot cert rotation** is
  deferred (Tier 2 COULD).

### 7.2 DNS scope

Ships with the substrate: pure-Zig resolver (Linux), `DnsQueryEx` (Windows),
`getaddrinfo`-on-the-blocking-pool (macOS — the pool's named target workload).
Happy-eyeballs is the default dial path (v1 caveat: OQ3). **Deferred:** SRV/TXT/MX,
TCP fallback on truncated responses, resolver caching.

### 7.3 Hermetic test strategy (networked tests without network flakiness)

- The suite uses **loopback only, ephemeral ports** (bind port 0 → `local_address` to
  discover), proven to work inside the build sandbox (probe 1). No external hosts in
  the automated suite.
- **S4 (TLS client) chicken-and-egg:** before the server exists, client TLS cannot be
  suite-tested hermetically. Resolution: S4's live-host verification (real HTTPS 200)
  is a **one-time, explicitly-gated manual verification** (like the campaign's
  user-run steps), plus unit tests over the record layer; **S5 retro-adds the
  hermetic loopback TLS suite** (Zap client ↔ Zap server self-tests) plus
  interop gates against `curl`/`openssl s_client`.
- Compile-fail contracts (copy-`send` of a live socket, use-after-move, gate-OFF
  `Socket.Active` w/o kernel, wasi `:network` rejection) follow the Test Placement
  rule: Zest where expressible; `zir-test` fixtures only where compile-fail harness
  support is required — **and `zig build zir-test` remains the user's to run.**

### 7.4 The one honest caveat — Tier 2's typed message

The *ideal* active-mode surface is a payload-bearing union
(`receive Socket.Event { Data(bytes) -> …; Closed -> … }`). That is currently blocked
by the "payload-bearing unions are unsendable" rule. The **shippable-today** form is a
single sendable **struct envelope** with an atom discriminant
(`Socket.Event { kind, bytes, reason, source }`) — a struct of sendables *is*
sendable, and a large `bytes` auto-promotes to the shared Blob tier. When the
sendability extension lands (already flagged as future work in the concurrency docs),
`Socket.Event` becomes a real union with **no surface change to the pump**. Ship the
expressible thing now, name the ideal, document the upgrade path.

---

## 8. Security considerations (a socket layer is an attack surface)

Named here so each lands as a deliverable, not an afterthought:

- **Mailbox-flood DoS:** active mode is credit-only (`{active, N}`); no uncapped mode
  exists. (Erlang's own docs: "a fast sender can easily overflow the receiver.")
- **Frame-size DoS:** framing helpers (S6) carry a mandatory `packet_size` cap;
  length-prefixed frames above the cap fail loudly rather than allocate.
- **Slowloris / idle connections:** idle timeouts are first-class (`timeout_ms` in
  Tier 1; `receive … after` in Tier 2) and appear in the canonical server examples.
- **Accept-flood / fd exhaustion:** `:emfile` is a typed, matchable error;
  `max_connections` load-shedding is a stdlib pattern (S3); acceptor pools park
  blocking-style (kernel FIFO fairness).
- **TLS posture:** no renegotiation; verification on by default; TLS 1.3-first;
  side-channel discipline on the server handshake (constant-time comparisons via
  std.crypto primitives); no silent downgrade.
- **Memory safety at the boundary:** stale/foreign handles panic via generation
  validation — never corrupt memory; fds never appear as raw values in Zap.
- **Untrusted bytes:** `Socket.Recv.Chunk` carries arbitrary bytes; binary pattern
  matching is the safe parsing surface; nothing interprets payloads implicitly.

---

## 9. Phased job breakdown (one-job-at-a-time + gap-loop, per the campaign discipline)

Each phase: implement the best long-term solution → gap analysis → resolve all gaps →
repeat until CLEAR → only then advance. No performance regressions (gate-OFF
byte-identity for non-socket programs must hold; concurrency benchmarks must not
regress). TDD: failing Zap/Zest tests first where expressible. **`zig build zir-test`
remains the user's to run.**

### Phase S0 — Foundations: socket domain + runtime bridge
- The **socket table / fourth allocation domain** (handle → fd/owner/generation/kind/
  state; pattern from `blob.zig` + `pid_table.zig`) + per-process socket ledger
  drained at teardown.
- `zap_proc_register_drop_resource` ABI export + socket-fd `close` destructor.
- `runtime.zig` `Socket` namespace bridging Zap ↔ `std.Io.net` through the
  offload-iff-kernel-live seam (Decision D); poll-quantum bounding (§6.1);
  socket-option application (resolve R3: seam vs fork contribution); blocking-pool
  `max_thread_count` knob.
- `lib/socket/address.zap`, `lib/socket/error.zap`, `lib/socket/options.zap`.
- Resolve OQ3 (v1 happy-eyeballs mechanics).
- **Exit gate:** loopback TCP open/close from Zap in both gate-ON and gate-OFF
  programs; fd closed on process exit *and* on kill (drop-list) verified; stale-handle
  use panics with generation diagnostics; gate-OFF byte-identity holds for non-socket
  programs; wasi rejects with the `:network` diagnostic.

### Phase S1 — Tier 1 TCP streams (the value-threaded handle)
- `Socket` + `Socket.Listener` full op set; `Socket.Recv` EOF-safe union; move-only
  cross-process ownership (`send_move`; copy-`send` rejected); user `timeout_ms`
  semantics (timeout ≠ close); `recv_exact`/`send_all`; `send`-failure `bytes_sent`
  reporting; `recv_blob`; half-close semantics; `local_address`/`peer_address`;
  happy-eyeballs default connect; accepted-socket option inheritance.
- **Streaming (§4.1 Form 1):** `Socket.chunks/2` implementing
  `Enumerable(Result(String, SocketError))` — parking pulls, `:done` on
  EOF/error/idle-timeout, borrow semantics (dispose never closes the socket; streams
  are resumable); **`Enum.reduce_while` as a general `Enum` contribution** +
  `Socket.fold/4` as thin sugar over it; `Enum`/`for` composition over live sockets;
  boundedness semantics per §4.1 documented in every relevant `@doc`.
- **Exit gate:** loopback echo roundtrip; `recv_exact`/EOF/timeout matrix;
  **binary-safe payloads** (NUL bytes, invalid UTF-8) roundtrip; `send_move` handoff
  works and use-after-move + copy-`send` are compile-rejected; shutdown(:write)
  graceful handshake works; **`Enum.reduce` and a `for` comprehension consume a live
  loopback stream to EOF; `Enum.take` early-exits and `dispose` releases the
  iteration state (fd/introspection-verified); a mid-stream reset surfaces as the
  final `Error` element; an idle-timeout ends the stream while the socket remains
  usable (a fresh `chunks` resumes); `Socket.fold`/`Enum.reduce_while` halts
  mid-stream on a live connection on a protocol condition**; Tier-0 stream items
  green.

### Phase S2 — Datagram + Unix-domain
- `Socket.Datagram`: UDP bind/send_to/recv_from with explicit truncation surfacing,
  connected-UDP; Unix-domain stream (listen/connect/accept via `Socket.Address.unix`)
  + Unix datagram.
- **Exit gate:** UDP loopback roundtrip incl. truncation case; connected-UDP filters;
  Unix stream echo + Unix dgram roundtrip; wasi/windows behavior per capability
  matrix.

### Phase S3 — Server side & supervision integration
- Acceptor-pool pattern (multi-process accept on one listener); per-connection handler
  processes; owner-executed `controlling_process` handover; **graceful drain per §6.2**
  (stop-message/kill + drop-list + `shutdown_timeout` stragglers); `max_connections`
  load-shedding; crash-safety.
- **Exit gate:** canonical echo server under a supervisor accepts N concurrent
  connections; handler crash is isolated + fd-reclaimed; drain closes the listener,
  aborts pending accepts, lets live connections finish, and force-closes stragglers
  after the timeout; `max_connections` sheds correctly.

### Phase S4 — TLS client
- `lib/tls.zap` (`Tls.connect`, `Tls.upgrade`) over `std.crypto.tls.Client`; OS trust
  store; SNI/ALPN; session state behind the same `Socket` handle; STARTTLS upgrade
  with consume semantics (OQ2 floor: dynamic generation-bump; static `unique` if
  available); the flush-composition gotcha handled.
- **Exit gate:** one-time gated live HTTPS verification (real host, 200 through the
  decrypted stream); cert-verification failure surfaces as a typed `SocketError`;
  record-layer unit tests; cross-compiles all targets. (Hermetic loopback TLS suite
  lands in S5 — §7.3.)

### Phase S5 — TLS server (approach per §7.1 — pure-Zig recommended, OQ0)
- Server handshake (TLS 1.3-first), cert/key PEM loading, per-SNI cert selection,
  ALPN selection; `Tls.listen`/`Tls.accept` (and `Tls.upgrade` on accepted plaintext)
  yielding the same `Socket` type; hermetic loopback client↔server suite; interop
  gates against curl/`openssl s_client`.
- **Exit gate:** Zap TLS echo/HTTP server completes real TLS 1.3 handshakes with
  standard clients; bad-SNI/no-matching-cert paths are typed errors; handler
  crash-safety + fd-reclaim hold under TLS; the S4 client is retro-verified against
  the Zap server hermetically; cross-compiles all targets.

### Phase S6 — Tier 2 active mode + stage integration (pure Zap over Tier 1)
- `Socket.Active` pump + `Socket.Event` envelope; credit-based `{active, N}` +
  typed passive-transition; `receive … after` idle timeout; multiplexing many sockets
  in one owner mailbox; datagram active mode with a per-readiness packet cap
  (`read_packets` lesson).
- **Stage integration (rev 4 — the `Stage`/`Stream`/`Framer` stdlib layer lands
  pre-campaign):** the pump accepts an arbitrary `Stage` (so `Socket.Active` can
  deliver whole frames/decoded values, not byte soup); `Socket.frames/2` =
  `Stream.transform(Socket.chunks(...), framer_stage)`; `Framer` stages carry the
  convergent contract (flush-at-EOF with leftover-bytes-defaults-to-error, mandatory
  max-frame bound, zero-copy Blob-slice frames where expressible).
- **`Stream.through_process`** — the one explicit async boundary: lifts an
  upstream into a supervised producer process feeding a credit-bounded typed mailbox;
  downstream keeps pulling as an `Enumerable`; overflow policy mandatory and visible
  (backpressure | drop_oldest | fail); zero-copy Blob moves across the boundary.
  Lives here because it needs process handoff + sendability machinery.
- **Exit gate:** an active-mode server multiplexes ≥2 sockets + a control message +
  an idle timeout in one `receive`; credit exhaustion throttles a fast sender (no
  mailbox growth); **the framer's pure Zest suite passes with zero I/O
  (frame-split-across-chunks, pathological one-byte fragmentation, cap violation)**;
  framed echo (length-prefix + line) works over active mode *and* via
  `Socket.frames` pull; oversize frame fails loudly at the cap.

### Phase S7 — HTTP client sanity layer (proves the abstraction)
- `HttpClient.get(url)` over the `Socket` layer; `http`/`https` differ only at
  connect; `with`-chained `Result`; binary pattern matching on the wire; `recv_all`
  body loop.
- **Exit gate:** `get("https://…")` and `("http://…")` both return parsed responses
  (hermetic against the S5 Zap server; gated live check optional); the layer below
  `open/1` is scheme-agnostic.

### Phase S8 — The netpoller (v2 — the scalable substrate swap)
- Poller thread + fd-interest registry (pid-generation-keyed); `.io_wait` state +
  yield reason; fd-readiness → `pushWake` bridge; timing-wheel timeouts replace
  poll-quanta; drop-list destructors deregister interests; **the 7.6 two-leg
  re-adjudication (§5.1) with the publish/arm ordering**; kqueue (macOS) + epoll
  (Linux) first, IOCP (Windows) as the fork-adjacent follow-in (R4).
- **Flow-control refinement (rev 4):** transport-layer credit denominated in
  **bytes** with dual pause/resume thresholds (the Pipelines anti-cycling design);
  the typed-message layer keeps **count-based** credits with batched regrant (grant
  N when N/2 consumed — Pekko's windowed strategy).
- **Exit gate:** thousands of concurrent connections on one poller thread; the sacred
  scheduler-local refcount invariant holds under TSan under real M:N parallelism; the
  7.6 detector has no false positive with live processes all parked on I/O and no
  false negative on a true deadlock; all S1–S7 suites pass unchanged on the poller
  substrate (the API is stable across the swap); v1 poll-quantum code is **removed**,
  not kept as a fallback.

### Phase S9 — Hardening, benchmarks, documentation
- Adversarial hardening pass over the whole stack (the §8 checklist as an audit);
  lock-free socket introspection counters wired into the existing introspection
  surface; throughput/latency/connection-scaling benchmarks recorded in the ledger
  style of `docs/concurrency-bench-results.md`; `docs/guides/sockets.md` with
  verified examples **including the Form-selection guidance and the
  safe-on-live-streams vs bounded-streams-only `Enum` table (§4.1 boundedness)**;
  README/CHANGELOG.
- **Exit gate:** hardening audit CLEAR; benchmarks published; guide examples verified
  by execution; no performance regression vs the S1-era baselines; capability matrix
  documented.

### Deferred / documented non-goals (numbered for tracking)
- **D2** DNS SRV/TXT/MX + TCP-fallback + caching; **D3** raw sockets; **D4** SCTP;
  **D5** OOB/urgent data; **D6** multicast/broadcast; **D7** `SCM_RIGHTS` fd-passing;
  **D8** `TCP_FASTOPEN`/MPTCP/`TCP_QUICKACK`; **D9** zero-copy `sendfile` (substrate
  `netWriteFile` exists; wire on a proxy/file-server use case); **D10** io_uring net
  backend; **D11** the payload-bearing `Socket.Event` union (awaits the sendability
  extension — §7.4); **D12** TLS client-cert auth (server side) + cert hot-rotation;
  **D13** kernel fast-path active-mode delivery (only with measurements, per
  Decision A); **D14** TLS 1.2 *server* support (client already has 1.2); **D15**
  wasm socket support via WASI preview2 `wasi-sockets` (gate-OFF only; awaits the Zig
  substrate gaining preview2 — §1.3); **D16** a lazy `Stream` adapter module (lazy
  `map`/`filter`/`take` composition over `Enumerable` without materializing) —
  general stdlib work sockets would benefit from but must not own;
  `Enum.reduce`/`each`/`take` + `Socket.fold` cover streaming consumption in this
  campaign.
  *(D1 server-side TLS was promoted into scope as S5. Windows gate-ON sockets are not
  a D-item of this campaign — they are the IOCP leg of the concurrency campaign's
  7.2a port, per §1.3/R4.)*

---

## 10. Risks & open questions

- **OQ0 — server-TLS approach (the one open decision):** pure-Zig on std's record
  layer (recommended) vs vetted C binding (§7.1).
- **OQ2 (downgraded) — `unique` on handle-typed parameters:** rev 2 flagged
  parameter-position uniqueness as possibly missing; it **exists and is pervasive** —
  `Enumerable.next(state :: unique Enumerable(element))` and every `Enum` HOF thread
  `unique` states (`lib/enumerable.zap:22`, `lib/enum.zap`). Remaining verification
  (S4): that a one-word handle struct (`Socket`) composes with `unique` exactly as
  collection states do. The floor remains dynamic enforcement (generation bump →
  stale-handle panic, memory-safe).
- **OQ3 — v1 happy-eyeballs mechanics** (sequential fallback vs dedicated Io
  instance) — resolve at S0; API unchanged either way.
- **R1 — v1 concurrency ceiling.** 64 shared blocking threads; tunable cap + honest
  docs; fully resolved by S8.
- **R2 — the 7.6 ordering discipline (S8).** The publish-before-decrement /
  arm-before-idle ordering is the single subtlest correctness point; it gets the
  adversarial gap-analysis + TSan treatment.
- **R3 — socket-option surface routing** (runtime_os seam vs fork `std.Io.net`
  option-surface contribution). Decide at S0.
- **R4 — Windows gate-ON is a cross-campaign dependency, not a socket work item.**
  Green-process socket servers on Windows require the concurrency campaign's 7.2a
  kernel port (futex/fiber/mmap/clock analogues), into which the S8 IOCP poller leg
  folds. This campaign delivers Windows gate-OFF sockets (§1.3) and keeps the S8
  poller design IOCP-compatible (the E9 reservation already accounts for completion-
  model backends, as OTP's `nowait`→select/completion split did); it does not attempt
  7.2a. macOS/Linux pollers land first.
- **R5 — server-TLS hardening burden (if OQ0 = pure-Zig).** Security-critical net-new
  code; mitigated by TLS 1.3-only scope, std crypto primitives, interop gates, and
  the campaign's adversarial gap-loops; upstreamable to the fork's std as
  `std.crypto.tls.Server`.
- **OQ1 — sendability extension timing.** Tier 2 ships as a struct envelope
  regardless; the union upgrade (D11) is independent.

---

## 11. Ratified scope (2026-07-12, restated under rev-2 numbering)

**Full scope: Phases S0 → S9.** The complete, competitive, functional-native stack in
one campaign — foundations, Tier-1 streams, datagram/Unix, server + supervision,
**client and server TLS**, Tier-2 typed active mode + framing, an HTTP client, **the
v2 netpoller**, and a hardening/benchmark/docs close-out. It carries the most
kernel-invasive piece (S8: poller + 7.6 re-adjudication) *and* the most
security-critical net-new piece (S5: the server-side TLS handshake) — both held to the
campaign's no-compromise bar with the one-job-at-a-time + gap-loop discipline, TSan on
the invariant, and no gate-OFF byte-identity regression.

**Sequencing rationale:** S8 runs after the API surface is landed and proven on the
blocking pool, so the poller swaps the suspension substrate underneath a stable,
tested API (and the v1 quantum mechanism is then deleted — no fallback retained). S5
follows S4 so the record-layer integration is exercised by the settled client path
first, and S5 then makes the whole TLS suite hermetic. S9 mirrors the concurrency
campaign's P7.

**The one decision still open before implementation begins: OQ0** — server-TLS
approach, with pure-Zig on std's record layer recommended.
