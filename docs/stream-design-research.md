# Stream Transformation Design for Zap — Research Synthesis & Decision Record

**Status: PROPOSED — awaiting approval.** Synthesizes three parallel deep-research
investigations (2026-07-12): BEAM indefinite-socket streaming (Elixir Stream /
GenStage / Broadway / production-library survey); typed-FP stream libraries (Haskell
lazy-IO→conduit/pipes/io-streams/streaming, Scala fs2/Akka/ZIO, the direct-style
counter-movement ox/gears/bluefin); and direct-style + transformation-oriented designs
(Clojure transducers/core.async/manifold, OCaml eio/Seq/Iter, Rust Stream/Framed,
F#/.NET AsyncSeq/Pipelines/Rx, Gleam, Go 1.23 iter, Java Gatherers). Full sourced
reports live in the session research record; this document is the decision-grade
distillation.

**The question:** should Zap implement an Elixir-like `Stream` (lazy enumerables)?
And how should streaming from a socket *indefinitely* work?

---

## 1. The five load-bearing findings

**F1 — On the BEAM, indefinite socket streaming was never won by Stream; it was won
by processes.** Every production library owning a never-closing connection (Phoenix,
WebSockex, gun, Mint) chose process-delivering-typed-messages. GenStage's own
announcement names the motivation: Streams stop at lazy — single-process, no
concurrency. The one Stream-based outlier (ExTwitter) hides an unbounded mailbox push
behind a pull facade. Gleam — the typed-BEAM datapoint — went further and *evicted*
its lazy iterator from the stdlib; its designer's contract ("supposed to be
replayable… a stream of logs: poor use") excludes sockets by definition.

**F2 — Fifteen years of typed-FP streaming machinery, decoded, is Zap's planned
operational core.** conduit's `sourceSocket`, pipes' `fromSocket` (with per-pull
timeout!), fs2's internal 8KiB-chunk read loop are all the same blocking pull loop as
`Socket.chunks`. The free-monad coroutines, `compile`/materialization, ResourceT/
scope-trees, and cooperative-interruption machinery exist to simulate cheap blocking
and dynamically-discovered cleanup — both of which Zap has natively (fibers;
`unique` + `dispose`). The famous prompt-finalization failures (Gonzalez on pipes,
Collins on io-streams) share one root cause — cleanup obligations discovered
dynamically — which linearity converts to compile-time ownership.

**F3 — The direct-style purist position ("a stream is just a loop") failed its own
test, four times.** Scala ox launched channels-only and reversed within a year
("each transformation stage introduced an asynchronous boundary… too much
concurrency" for a mere `map`). Kotlin abandoned channel-operators for cold
sequential `Flow` (hot channels leak suspended producers and open connections). Go
added `iter` after 14 years ("no standard way to iterate"). Java — whose architects
called reactive "transitional" — shipped Gatherers. All four converged on the same
shape: **cold, lazy transformation values; sequential same-fiber execution by
default; concurrency/buffering only at explicit operators; a completion/flush hook
for stateful stages; hot channels/mailboxes kept for intrinsically-hot sources.**
Gleam, the purest "nothing" ecosystem, shows the predicted symptom: no shared
transformation vocabulary, so every library invents a bespoke pull-closure protocol
(mist's `Chunk.consume`).

**F4 — Transducers are the right idea in the wrong encoding.** The promise (one
transformation value across collections/channels/streams) genuinely held in Clojure's
blessed single-consumer contexts — and the idea keeps being re-derived (ox Flow
stages, Kotlin Flow operators, Go Seq funcs, Java Gatherers). But the encoding breaks
where Zap cares most: state hides in `volatile!` closures with an informal
"one-owner, unsafe-across-threads" contract (hostile to `unique` discipline); errors
were never unified across contexts (silent-skip default on channels); stateful
transducers are unusable in parallel pipelines — an *intrinsic* limit (a stateful
stage IS a sequential fold), which Java made legible by requiring an explicit
`combiner` for parallel-capable Gatherers.

**F5 — Every ecosystem converged on the same two-layer socket kernel.** A stateful,
byte-denominated framing kernel (tokio `Decoder`, .NET `PipeReader`, eio `Buf_read`,
gloss codecs) under an item-level abstraction. The contract details repeat across
all of them: a distinct **end-of-stream flush** entry point (tokio `decode_eof`,
transducer completion-arity, Gatherer finisher — a bare fold cannot emit the final
partial frame); **leftover-bytes-at-EOF defaults to an error**; a **max-frame-size
DoS bound**; zero-copy frame slices of the read buffer. And two credit currencies:
**bytes** at the transport layer (Pipelines' pause/resume dual thresholds), **message
counts** at the typed layer (`{active, N}`, Reactive-Streams `request(n)`).

---

## 2. The options, evaluated in Zap's context

### Option A — Elixir-style `Stream` module (lazy iterator adapters)

| Strengths | Weaknesses |
|---|---|
| Surface familiarity for Elixir users; validated by the four-ecosystem convergence (F3) | Elixir's *encoding* (suspended reducers over internal iteration) is an artifact of Elixir's protocol — wrong model to copy; Zap's pull protocol makes adapters plain wrapper structs |
| Trivial to build on Zap's `Enumerable` (external iteration = Rust-style wrappers); monomorphization avoids the thunk-chain tax that got Gleam's iterator evicted | Transformation logic is locked to the pull context: a windowing/dedupe/framing transformation written as an adapter cannot be reused in an active-mode receive loop or a pipeline stage without reimplementation — and Zap has *three* first-class consumption forms |
| `unique` + `dispose` statically fix every documented pull-type hazard: OCaml Seq's ephemeral-reuse crash, Gleam's replayability contract, abandonment leaks, Rust's cancel-safety holes | Scope must be policed: the BEAM verdict (F1) stands — adapters must not become the connection-ownership abstraction |
| Backpressure composes for free (demand-1 to the socket, out over TCP) | Bare adapters lack the flush hook (F5) unless a stage-like core exists underneath |

### Option B — Clojure-style transducers

| Strengths | Weaknesses |
|---|---|
| One transformation value across contexts — and Zap, with three consumption forms, has the strongest *need* for this of any language surveyed | Closure-hidden mutable state with informal ownership is actively hostile to Zap's linear/`unique` discipline — it smuggles mutation past the type system |
| Fusion performance; no intermediate collections | Error handling never unified across contexts (Clojure channels: silent-skip default) |
| The completion-arity is the proven flush hook (F5) | Breaks intrinsically at parallel stages (stateful xform in `pipeline` is forbidden); cross-language portability record is poor; composition-order inversion is a permanent teaching hazard |

### Option C — Nothing: `fold`/`reduce_while` + processes only

| Strengths | Weaknesses |
|---|---|
| Smallest surface; the direct-style purist position (Pike, Pressler); processes are Zap's native strength | Contradicted by the strongest direct-style practitioners' own reversals (F3) — ox abandoned exactly this within a year; per-stage processes = mailbox copies + scheduler hops + supervision plumbing for stages with zero concurrency content |
| IO layer genuinely needs nothing (eio proves loop + buffered parsing end-to-end) | Gleam shows the end state: bespoke incompatible pull-closure protocols per library |
| | Bare folds cannot express the final-partial-window flush (F5) — Zap already conceded this by designing `Framer.push` with carried state |

### Option D — Stage values (Gatherers-with-linearity) + adapters as sugar + one explicit boundary

The synthesis the evidence points to. A **stage** is a first-class transformation
value with *explicit, linearly-threaded state* — the purified transducer; Java
Gatherers with linearity instead of documentation; the generalization of the already-
designed `Framer`:

```
Stage(input, output):
  init  :: fn() -> state
  step  :: fn(state, input) -> {[output], state} | {:halt, [output], state}
  flush :: fn(state) -> [output]        # end-of-stream completion (F5)
```

| Strengths | Weaknesses / costs |
|---|---|
| Captures the real transducer benefit — write `dedupe`/`window`/`length_prefixed` once — in the *only* encoding compatible with `unique`: state is an explicit value, threaded and checked, never closure-hidden | A composite abstraction assembled from precedents (Gatherers init/integrator/finisher + tokio Decoder/decode_eof + transducer completion-arity + linearity) rather than copied whole from one ecosystem; needs careful spec work (dispose-through-flush ordering on early exit, error propagation, composition laws as tested equations) |
| One vocabulary across all three consumption forms via three thin drivers: (1) pull — wrap `Enumerable` + stage → new `Enumerable`; (2) push — fold the stage over typed mailbox events in the pump/receive loop; (3) pipeline — lift a stage into a supervised process moving Blob outputs downstream | More design surface than plain adapters alone |
| The stateless/stateful distinction is legible and honestly gates parallelization (the Clojure lesson, Gatherers-corroborated): stateless stages run anywhere; stateful stages are sequential values, parallelizable only via explicit combiner/partitioning | |
| `Framer` stops being a special case — it becomes the flagship `Stage` instance, inheriting the F5 contract (flush, leftover-at-EOF error, max-frame bound, zero-copy Blob slices) | |
| Monomorphized adapter chains approach Rust's fused state machines | |

---

## 3. Recommendation

**Build Option D, surfaced through an Elixir-familiar `Stream` module.** Concretely:

1. **`Stage` (general stdlib, not socket-owned)** — the transformation-value core:
   `init/step/flush` over linearly-threaded state; `{:halt, ...}` early termination;
   composition `Stage.compose(a, b)`; the doctrine that stateful stages are
   sequential (parallel lift requires stateless or an explicit combiner).
2. **`Stream` — lazy adapters over `Enumerable`, implemented on `Stage`** — the
   Elixir-familiar face: `map`, `filter`, `reject`, `take`, `take_while`, `drop`,
   `drop_while`, `scan`, `chunk_every`, `with_index`, `zip`, `unfold`, `transform
   (stage)`. Cold, sequential, same-fiber, fused by default; `dispose` propagates
   through adapter chains (early exit runs `flush` policy then disposes inward —
   specified, tested). Chunk-preserving by default over `Socket.chunks`;
   per-element adapters explicit and loud (the fs2 lesson).
3. **One explicit async boundary** — `Stream.through_process(stream_or_stage, opts)`:
   lifts the upstream into a supervised producer process feeding a credit-bounded
   typed mailbox; downstream keeps pulling as an `Enumerable`. Overflow policy is a
   mandatory, visible option (backpressure | drop_oldest | fail — never a silent
   default). Zero-copy Blob moves across the boundary — an edge no surveyed
   ecosystem has. This is ox's `.buffer()`/Kotlin's `flowOn` made supervision-native,
   and the only place concurrency enters the transformation layer.
4. **`Framer` = `Stage` instances** (`Framer.length_prefixed(n, max)`,
   `Framer.line(max)`), carrying the F5 contract: `flush` at EOF with
   leftover-bytes-defaults-to-error, mandatory max-frame bound, zero-copy Blob-slice
   frames. Usable identically in pull chains, the active-mode pump, and pipeline
   stages — the unification made real.
5. **Doctrine (docs + `@doc`, enforced by review):** connection *ownership* for
   indefinite sockets stays with processes — credit-based active mode (Form 2) or
   supervised pipelines (Form 3); pull streams are the single-owner, in-fiber
   consumption mode for bounded transfers, until-EOF flows, and protocol phases. No
   combinators over mailboxes themselves (no ecosystem built them; channels stay hot
   endpoints bridged by adapters). No GenStage-style demand framework — credits sit
   at the true edge (TCP window / `{active, N}`), which is where Broadway ended up
   anyway. Linked teardown in pipelines wired deliberately (links/monitors) so a dead
   consumer cannot strand a parked reader.
6. **Kernel refinement for the socket plan (S8):** transport-layer flow control
   denominated in **bytes** with dual pause/resume thresholds (Pipelines' anti-cycling
   design); typed-message layer keeps **count-based** credits with batched regrant
   (grant N when N/2 consumed — Pekko's windowed strategy).

**What we deliberately do NOT build:** Elixir's suspended-reducer Stream encoding;
classic closure-state transducers; combinators over mailboxes; a demand-protocol
framework; reified graph topologies (a topology is processes under a supervisor);
lazy byte-element streams as a primary API (chunks are the element).

**Why this is right for Zap specifically:** Zap is the only language surveyed holding
all three winning positions at once — cheap blocking pull (Go/eio), typed
credit-push mailboxes (Erlang), and linear state (Rust-adjacent, but with `dispose`).
Option D is the unique design that lets one transformation vocabulary ride all three,
with the type system enforcing the two contracts every other ecosystem left to
documentation: state ownership (linearity) and end-of-stream completion (flush as a
protocol obligation, not a convention).

---

## 4. Impact on the socket implementation plan (on approval)

- Replaces the suspended "S1b Stream module" scope with: **Stage core + Stream
  adapters + through_process boundary** (one phase, after S1; general-stdlib work
  contributed by the campaign, like `Enum.reduce_while`).
- S6 (active mode + framing) amends: `Framer` becomes `Stage` instances; the pump
  accepts arbitrary stages; framing exit gates gain flush/leftover/max-frame cases.
- S8 (netpoller) amends: byte-denominated dual-threshold transport credits.
- §4.1 Form-selection doctrine gains the ownership-vs-transformation distinction
  (processes own indefinite connections; streams transform within an owner).
