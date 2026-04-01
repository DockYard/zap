# Syntax Design for an Agentic Functional Programming Language

## Executive summary

Agentic coding systems (LLM-based agents that plan, act via tools, and iterate based on feedback) consistently benefit from **interfaces that are explicit, structured, and machine-checkable**, rather than “clever” or highly implicit language features. This conclusion is supported by research showing that agent performance depends heavily on the design of the agent–environment interface (e.g., SWE-agent) and on the availability of structured tool calling rather than free-form text actions. citeturn12view5turn12view0turn15view0

For a functional language optimized for agentic coding, the most effective default syntax is an **ML/Rust-like expression language** (explicit delimiters, explicit pattern matching, explicit module paths) paired with a **typed effect system** (row-polymorphic effects + algebraic effect handlers) and **capability-based security** (effects are only available when the corresponding capability is in scope). Typed effects make side effects locally visible “in the code you can grep,” while effect handlers keep the language modular and composable—especially for concurrency. citeturn13view0turn12view3turn24view0turn19view0

Recommended default choices (high-level):

- **Static typing with Hindley–Milner-style inference**, but require *explicit type + effect signatures at module boundaries* (public/exported definitions). This preserves ergonomics while making code locally interpretable without an IDE. citeturn8search9turn20view0turn14view0  
- **Row-polymorphic effect types (Koka-style) + algebraic effect handlers (Plotkin–Pretnar-style)** as the primary mechanism for I/O, state, exceptions, and concurrency scheduling. This yields: (a) explicit “what might happen” at call sites, (b) modular replacement/mocking of effects (supporting testability), and (c) user-defined schedulers for concurrency. citeturn13view0turn12view3turn24view0turn1search3  
- **Structured concurrency** as the default concurrency model (nursery/scoped tasks with cancellation), with actor-style concurrency offered as a library/standard module for distributed patterns. Structured concurrency improves safety and makes failure propagation/cancellation semantics explicit. citeturn7search1turn7search0turn17view1  
- **Typed error values (`Result`) with a propagation operator** for the common case, reserving exceptions primarily as an effect that must be declared/handled. This aligns with evidence that explicit error paths improve robustness and reduces “catch-all” anti-patterns common in agent-generated code. citeturn23view0turn14view0  
- **First-class provenance** integrated into the runtime and type system: tool calls, builds, and code-generation steps automatically emit provenance nodes compatible with W3C PROV concepts and supply-chain provenance practices. citeturn12view4turn31view0turn31view1  
- **Default sandboxing via WebAssembly/WASI** plus capability scoping: untrusted plugins and agent-generated code run with narrowly granted capabilities. citeturn16view0turn19view0  

The remainder of this report proposes concrete syntax (code snippets) for each feature requested, explains why each design supports agentic coding, and compares alternatives.

## Evidence base and evaluation lens

Agentic coding (as a paradigm) is characterized by goal decomposition, iterative interaction with tools (compilers, test runners, VCS), and feedback-driven refinement. Surveys emphasize that agentic systems require robust tool integration, monitoring, and state management, and that existing tools/languages are largely human-centric. citeturn15view0turn12view5

Three findings directly shape syntax recommendations:

First, **tool and environment interfaces directly impact success rates**. SWE-agent argues that LMs are “a new category of end users” and shows that a custom agent–computer interface improves an agent’s ability to edit files, navigate repos, and execute tests. Syntax is part of that interface: it affects how reliably an agent can produce edits and interpret feedback. citeturn12view5turn9search0

Second, **structured tool calling beats ad-hoc text protocols**. Official tool-calling docs from entity["company","OpenAI","ai company"] describe function/tool calling as being defined by JSON Schema, and structured outputs as enforcing JSON Schema conformance. These are exactly the properties a language can exploit by deriving schemas from its types. citeturn12view0turn12view1

Third, industry experience increasingly suggests that **agents need orchestration logic in code**, not purely through repeated natural-language invocations. entity["company","Anthropic","ai company"] explicitly argues for “programmatic tool calling,” where code orchestrates loops/conditionals/tool pipelines and only summarized results enter the model context. This strongly supports a functional language that treats tool calls as typed effects and makes orchestration a first-class programming task. citeturn18view0

Evaluation criteria used throughout this report (matching the user’s requested comparative table):

- **Expressiveness**: can the syntax encode rich abstractions (effects, concurrency, data modeling, metaprogramming) without contortions?
- **Safety**: does the syntax encourage/enable static checking against common failures (unsafe I/O, data races, privilege leaks, unhandled errors)?
- **Learnability**: can a competent developer (and an agent trained on existing corpora) use it reliably?
- **Toolability**: does the syntax admit robust parsing, refactoring, semantic tooling, and structured interfaces (e.g., LSP, schema extraction)?
- **Runtime performance**: does the design avoid pathological overheads and support efficient compilation/execution where possible?

## Language goals for agentic coding

This section explicitly addresses the requested dimensions: agentic coding capabilities, safety, interpretability, verifiability, composability, concurrency, and state management.

### Agentic coding capabilities

A language optimized for agentic coding should treat “agent loops” as a normal workload: plan → act (tool calls) → observe → revise. ReAct formalizes interleaving reasoning traces with actions and shows improved interpretability/diagnosability from trajectories that expose intermediate reasoning + actions. citeturn30view2 A language can mirror this by providing explicit constructs for workflows, step logs, and typed tool calls (instead of leaving all of it to ad-hoc string prompts).

### Safety and security

LLM agents are powerful automation but also amplify mistakes at scale. Two complementary language-based safety strategies are well-supported by primary sources:

- **Capability-based security**: object-capability models support least privilege and help avoid confused deputy vulnerabilities; the “Capability Myths Demolished” paper articulates these advantages and clarifies confinement/revocation misconceptions. citeturn19view0  
- **Language-based information-flow control**: security type systems can enforce information-flow policies statically, including tracking implicit flows (e.g., via program-counter labels). citeturn19view2  

For agentic coding, these become critical because agents will frequently glue together tools, credentials, and data sources.

### Interpretability

Interpretability in this context is not “model interpretability,” but **human-auditable program intent and behavior**:

- explicit effect signatures (“this function can touch the filesystem”),
- explicit error channels (`Result`),
- explicit provenance (what tool produced which artifact, with what inputs).

ReAct emphasizes interpretable trajectories; provenance standards (W3C PROV; SLSA provenance; in-toto) formalize audit trails. citeturn30view2turn12view4turn31view0turn31view1

### Verifiability

Verifiability ranges from lightweight to heavyweight:

- **Lightweight static guarantees**: HM typing already catches broad classes of errors; effect typing can guarantee absence of unhandled exceptions when the `exn` effect is absent (Koka claim). citeturn13view0turn8search9  
- **Refinement types**: Liquid Types combine HM inference with decidable predicates to prove safety properties with relatively low annotation burden. citeturn10search0turn10search4  
- **Proof-oriented programming**: F★ shows a practical “pay-as-you-go” model: write idiomatic ML-like code with no extra burden, but add specifications/proofs as needed using SMT + manual proofs. citeturn21view0turn21view1  
- **Proof-carrying code**: PCC frameworks attach machine-checkable proofs to code so a host verifies safety policies before execution; foundational PCC motivates minimizing the trusted computing base. citeturn26view0  

An agentic language should let teams choose where on this spectrum each module sits.

### Composability, concurrency, and state management

Concurrency and state are where agent-generated systems often fail (race conditions, hidden shared state, flaky tests). Primary sources support three composable approaches:

- **Algebraic effect handlers**: modularize control-flow and effects; OCaml notes they generalize exceptions and can express lightweight threads/coroutines/async I/O. citeturn12view3  
- **User-level schedulers**: Multicore OCaml experience argues for allowing programmers to define schedulers and shows effect handlers can represent scheduler interfaces. citeturn24view0  
- **Software transactional memory (STM)**: compositional transactions avoid lock composability issues; the “Composable Memory Transactions” paper provides semantics and composable primitives like `retry` and `orElse`. citeturn29view0  

State management can be: (a) immutable by default, (b) locally encapsulated mutation (ST/runST style), and (c) transactional shared state (STM). The ST approach is classically used to encapsulate mutation behind pure interfaces. citeturn8search0turn13view0

## Syntax proposal for a functional agentic language

This section proposes concrete syntax examples for each requested feature and explains why the syntax supports agentic coding, including trade-offs and alternatives. The proposed language is referred to as **AgentFP** (a placeholder name).

### Declaration vs inference

**Default choice**: HM-style local inference, explicit types/effects required at module boundaries (`pub`). This balances ergonomics with “local reasoning without IDE,” aligning with both ML tradition and observed agent friction when type info requires an LSP. citeturn20view0turn14view0turn8search9

Proposed syntax:

```agentfp
pub fn parse_config(text: String) -> Result<Config, ParseError> !{exn} {
  // inferred locals
  let tokens = lex(text);
  build_config(tokens)?
}
```

Why this helps agentic coding:

- Agents frequently edit small slices of code; exported signatures create stable anchors for refactoring and tool schema extraction (toolability).
- `!{exn}` makes the possibility of throwing (or signaling) an exception-like effect explicit at the boundary, improving “grep-level” interpretability. (Effect typing as a discipline is a central motivation in Koka.) citeturn13view0

Alternative: require full explicit typing everywhere. This improves readability but severely harms learnability and velocity, especially for agents that must synthesize lots of boilerplate.

### Purity and side-effect syntax

**Default choice**: functions are pure unless their type declares effects; effectful operations are explicit via `perform` (like effect systems in the literature and OCaml). citeturn12view3turn1search3

```agentfp
effect Log : { level: LogLevel, msg: String } -> Unit

pub fn greet(name: String) -> String !{log} {
  perform Log({ level: Info, msg: "Greeting user" });
  "Hello, " + name
}
```

Why this helps agentic coding:

- The surface syntax makes side effects obvious both to humans and to automated reviewers.
- Tests can handle/replace `Log` with deterministic collectors using handlers (see below), improving reliability and reducing flaky behavior.

Trade-off: `perform` is additional syntax overhead; however, agentic development values explicitness over minimal keystrokes, consistent with industry commentary that “cost of typing is going down” and local reasoning matters more. citeturn14view0

### Effect systems

**Default choice**: **row-polymorphic effect types** (Koka-style) in the function type, inferred where possible, but surfaced in exported signatures. This improves modular composition and supports reasoning like “no `exn` effect ⇒ cannot throw an unhandled exception.” citeturn13view0

```agentfp
// Row-polymorphic effect variable `e`
fn map<A, B>(f: A -> B !{e}, xs: List<A>) -> List<B> !{e} {
  match xs {
    []      -> []
    x :: xt -> f(x) :: map(f, xt)
  }
}
```

Why this helps agentic coding:

- Agents can refactor code mechanically while preserving effect polymorphism (“map preserves the effects of f”), improving toolability for automated transformations.

Alternative: monads (see next subsection) provide effect discipline but can become syntactically heavy; effects + handlers often give more direct-style code while retaining modularity. citeturn1search1turn1search3turn12view3

### Algebraic data types (ADTs) and pattern matching

**Default choice**: ML-style ADTs and exhaustive pattern matching (with compiler checking). This is well-established in OCaml-family syntax and supports clear, locally interpretable control flow. citeturn4search0turn4search4

```agentfp
pub type Expr =
  | Int(value: Int)
  | Add(left: Expr, right: Expr)
  | Var(name: String)

pub fn eval(env: Map<String, Int>, expr: Expr) -> Result<Int, EvalError> {
  match expr {
    Int(n)      -> Ok(n)
    Add(a, b)   -> Ok(eval(env, a)? + eval(env, b)?)
    Var(x)      -> env.get(x).ok_or(EvalError::UnboundVar(x))
  }
}
```

Why this helps agentic coding:

- ADTs + pattern matching create “structured diffs”: agents can add constructors and update match arms systematically.
- Tooling can derive JSON schemas and exhaustive coverage tasks.

Trade-off: exhaustive matching can be verbose; macros or derived functions can help, but macro use should be restrained (see metaprogramming below). citeturn14view0turn27view0

### Higher-order functions

**Default choice**: lightweight lambdas with explicit `|args|` or `fn(args) => ...`, plus effect-polymorphism (above). Example:

```agentfp
let xs = [1, 2, 3];
let ys = xs.map(fn(x) => x * 2);
```

Agentic advantage: HOF-heavy code tends to be concise; however, to preserve interpretability without an IDE, exported functions should still show types/effects explicitly at boundaries. citeturn14view0turn20view0

### Monads vs effect handlers for effects

Monads are foundational for structuring effects in FP (Moggi; Wadler). citeturn1search0turn1search1 In an agentic language, monads remain valuable—especially for library interop—but effect handlers offer two syntactic wins:

- direct-style code (less “plumbing”),
- modular interpretation (swap handlers for tests/simulations).

OCaml’s effect handler docs explicitly position handlers as generalizations of exception handlers that can express async I/O and lightweight threads. citeturn12view3

**Default choice**: effect handlers in the language core; monads are libraries.

### Error handling

**Default choice**: explicit `Result<T, E>` with a propagation operator `?`, mirroring successful patterns in Rust’s design and documentation. citeturn23view0

```agentfp
pub fn read_int(path: Path) -> Result<Int, IoError> !{fs} {
  let text = fs.read_text(path)?;   // `?` propagates Err
  parse_int(text)?
}
```

Why this helps agentic coding:

- Forces errors into the type signature, preventing “silent failure” and reducing the agent tendency to catch-all exceptions.
- `?` keeps code concise while preserving explicit control flow. citeturn23view0turn14view0

Alternative: unchecked exceptions; this harms reliability and makes it harder for agents to reason about control flow, consistent with industry observations. citeturn14view0

### Concurrency primitives

Agentic systems often need concurrency: parallel tool calls, parallel tests, background indexing, etc. Two primary-source-backed principles guide syntax:

- composability matters (STM paper shows lock composition pitfalls and composable alternatives), citeturn29view0  
- schedulers and concurrency models should be programmable (Multicore OCaml experience). citeturn24view0  

**Default choice**: **structured concurrency** + effect-based async I/O.

Proposed syntax:

```agentfp
pub fn fetch_all(urls: List<Url>) -> List<Response> !{net, cancel} {
  nursery {
    let tasks = urls.map(fn(u) => spawn net.get(u));
    tasks.map(await)
  }
}
```

Rationale:

- `nursery { ... }` is a scoped region that ensures spawned tasks complete/cancel before exit, matching structured concurrency principles used in modern async libraries (e.g., Trio docs). citeturn7search1turn7search0  
- `cancel` as an effect makes cancellation explicit and testable.

Alternative: pervasive `async/await` without structured scoping. This is familiar but can make lifecycle/cancellation implicit; structured concurrency encodes lifecycle in syntax.

**Complementary option**: actor model as a library for distributed orchestration (not the default). This aligns with industry frameworks adopting actor-like orchestration for multi-agent systems, and with actor-model reliability motivations (Erlang thesis). citeturn17view1turn7search3

### State management

**Default choice**: immutable data by default + two explicit state mechanisms:

- **encapsulated local mutation** with region tokens (ST-style),  
- **transactional shared state** with `atomic` blocks (STM-style).

Encapsulated mutation (ST/runST) is a long-standing technique: Koka explicitly connects effect typing to safely encapsulating state, analogous to Haskell’s `runST`. citeturn13view0turn8search0

Proposed syntax:

```agentfp
pub fn stable_sort(xs: List<Int>) -> List<Int> {
  region r {
    let a = MutArray::from_list(r, xs);
    a.sort_in_place();
    a.to_list()
  }
}
```

Transactional syntax (inspired by STM interface):

```agentfp
pub fn transfer(a: Account, b: Account, amt: Money) -> Unit !{stm} {
  atomic {
    a.balance -= amt;
    b.balance += amt;
  }
}
```

STM’s compositionality argument and primitives like `retry/orElse` show how to keep blocking/choice composable. citeturn29view0turn8search1

### Type system: static vs gradual, dependent/linear/affine types

#### Static vs gradual typing

**Default choice**: static typing by default; optional gradual “escape hatch” via `Dyn` for interop and prototyping, but discouraged in core modules.

Gradual-typing research defines “unknown type” (`?`) and emphasizes the “gradual guarantee” as a design criterion. citeturn28view1

Proposed syntax:

```agentfp
// discouraged in core logic; allowed at interop boundaries
pub fn parse_loose(json: Dyn) -> Dyn { ... }
```

Trade-off: gradual typing improves rapid iteration but complicates reasoning and can reduce toolability if overused.

#### Dependent / refinement types

**Default choice**: refinement types (Liquid Types style) as an optional layer; full dependent types in a “proof mode” (leaning toward F★/Idris/Lean experience).

Liquid Types: HM inference + predicate abstraction to infer dependent-like properties with lower annotation cost. citeturn10search0turn10search4  
F★: pay-as-you-go verification with dependent types + effectful programming + SMT discharge. citeturn21view0turn21view1  
Idris and Lean show dependent types + extensibility/metaprogramming as practical for programming + proving. citeturn5search8turn5search1

Proposed syntax (refinement type alias):

```agentfp
type NonEmptyString = { s: String | s.length > 0 }

pub fn head(s: NonEmptyString) -> Char {
  s.chars().first()
}
```

Agentic advantage: agents can generate/refine specs iteratively, and SMT-backed checks provide machine-verifiable feedback loops.

#### Linear / affine types

**Default choice**: affine-by-default ownership for resource handles (file descriptors, network sockets) and optional linear arrows for protocols, inspired by Linear Haskell’s decision to attach linearity to function arrows. citeturn22view0

Proposed syntax:

```agentfp
// `->1` = linear function arrow (argument must be used exactly once)
pub fn close(sock: Socket) ->1 Unit !{net} { ... }
```

Why this helps agentic coding:

- prevents resource leaks and “double close” errors that agents often introduce during refactors.
- supports protocol correctness and safe encapsulated mutation (Linear Haskell examples include enforcing protocols in I/O-performing functions). citeturn22view0

### Module and namespace syntax

**Default choice**: ML-style explicit interfaces (signatures) with a simple, greppable module path discipline.

The Definition of Standard ML emphasizes signatures as interfaces that prevent mismatched module composition and support separate compilation. citeturn20view0

Proposed syntax:

```agentfp
pub module HashMap : sig
  pub type Map<K, V>
  pub fn empty<K, V>() -> Map<K, V>
  pub fn insert<K, V>(m: Map<K, V>, k: K, v: V) -> Map<K, V>
end = struct
  ...
end
```

Greppability principle: discourage wildcard imports; require module-qualified references by default:

```agentfp
import Crypto.Hash as Hash

let d = Hash.sha256(bytes);
```

This aligns with industry observations that explicit module paths help agents “local reason” without running an LSP. citeturn14view0

### Macros and metaprogramming

Metaprogramming is powerful but risky for agents: it increases semantic distance between source text and executed code.

Two primary traditions:

- **typed quoting/splicing (Template Haskell)** supports compile-time code generation with typechecking of generated code. citeturn27view0  
- **hygienic macros (Racket/Scheme lineage)** support safe syntactic abstraction. citeturn4search3  

**Default choice**: provide metaprogramming, but constrain it:

- Prefer generics + derives for routine boilerplate.
- Allow *typed quotation macros* for code generation, but discourage arbitrary parser-rewriting macros.

Proposed syntax:

```agentfp
// derive common instances; avoids bespoke macros:
#[derive(Eq, Ord, Show, Json)]
pub type User = { id: UserId, name: String }

// typed quote/splice:
macro fn make_getter(field: Ident) -> Expr {
  quote { fn(x) => x.${field} }
}
```

Trade-off: restricting macros reduces expressiveness for DSLs; however, agentic coding benefits from predictability and toolability, and industry commentary suggests agents often struggle with macros. citeturn14view0turn27view0

### Interoperability

**Default choice**: a typed FFI surface plus a first-class Wasm/WASI compilation target for sandboxed plugins and cross-language composition.

WASI describes itself as a standards-track system interface designed to provide a secure standard interface for Wasm modules across environments and languages. citeturn16view0

Proposed syntax:

```agentfp
extern "c" {
  fn sqlite3_open(path: CString) -> Ptr<Db>;
}

pub module Plugin = wasm_component {
  export fn analyze(input: Bytes) -> Bytes
}
```

Agentic advantage: agents can safely run generated or third-party code in a sandboxed component, granting only explicitly requested capabilities.

### Tooling support

**Default choice**: ship an official language server compliant with LSP and a stable compiler “analysis API” that exposes typed AST/IR.

LSP standardizes editor–language-server communication for features like completion and go-to-definition. citeturn32view0turn32view1  
Separately, agentic research emphasizes that agents need structured internal state/feedback beyond plain error strings. citeturn15view0turn12view5

AgentFP should therefore expose:

- machine-readable diagnostics (JSON),
- typed holes with goals,
- “explain type/effect of expression” without running a full IDE,
- deterministic formatting to minimize diffs.

## Agent affordances, provenance, and security model

This section addresses the requested “agent affordances (explicit intent annotations, planning primitives, prompt embedding, provenance tracking)” and “security/sandboxing,” with concrete syntax and design rationale.

### Explicit intent annotations

**Default choice**: structured attributes that compile into metadata for tooling and provenance.

```agentfp
#[intent(
  goal: "Implement feature: add rate limiting",
  constraints: { no_new_deps: true, preserve_api: true }
)]
pub fn handle_request(req: Http.Request) -> Http.Response !{net, clock, log} {
  ...
}
```

Why this helps agentic coding:

- Agents can propagate intent metadata through refactors; reviewers can audit that changes respected constraints.
- Tooling can use intent tags to prioritize warnings (e.g., “introduces new dependency despite constraint”).

This mirrors ReAct’s emphasis on exposing plan/trajectory for interpretability, but in a machine-checkable form. citeturn30view2

### Planning primitives

**Default choice**: a small planning DSL that produces a typed plan graph which can be executed, logged, and replayed.

```agentfp
pub type Step =
  | ReadFile(path: Path)
  | RunTests(selector: TestSelector)
  | ApplyPatch(diff: Patch)
  | Summarize(msg: String)

pub fn plan_fix(issue: Issue) -> Plan<Step> {
  plan {
    step ReadFile(issue.entrypoint);
    step RunTests(All);
    step Summarize("Iterate until tests pass");
  }
}
```

Agentic advantage: plans become first-class values with provenance, which can be compared, diffed, and replayed.

### Prompt embedding and typed tool calls

Because tool calling is now commonly schema-based (JSON Schema for function tools; structured outputs guarantee conformance), a language can unify:

- external tools (filesystem, git, web search),
- LLM calls (planner, code generator, reviewer),
- structured outputs.

The entity["company","OpenAI","ai company"] tool calling guide describes function tools as defined by JSON schema. citeturn12view0 Structured outputs ensure model responses adhere to supplied JSON Schema. citeturn12view1

Proposed syntax:

```agentfp
tool fn llm.complete<A>(
  prompt: Prompt,
  schema: JsonSchema<A>,
  temperature: Float = 0.0
) -> A !{llm}

let p = prompt"""
You are a coding assistant.
Return a patch and a rationale.
""";

type PatchProposal = { diff: Patch, rationale: String };

let proposal: PatchProposal =
  llm.complete(p, schema_of<PatchProposal>());
```

Why this supports agentic coding:

- The language compiler can derive `schema_of<T>()` from type definitions, making LLM/tool IO verifiable.
- Schemas enable deterministic parsing and enforcement (reduce “hallucinated fields”), aligning with structured-output guarantees. citeturn12view1

Industry experience emphasizes that agents also need **programmatic tool calling** (orchestration in code) to avoid repeated inference passes and context pollution. citeturn18view0 AgentFP supports this naturally by making tool calls regular expressions in the language with typed results.

### Provenance tracking

**Default choice**: every tool call and build step yields a value annotated with provenance, exportable as a PROV-compatible graph.

W3C PROV-DM defines provenance concepts (entities, activities, agents, derivations, bundles). citeturn12view4 SLSA provenance defines provenance as verifiable information describing where/when/how artifacts were produced, within an in-toto attestation framework. citeturn31view0turn31view1

Proposed syntax:

```agentfp
let r: Prov<Web.SearchResult> = web.search("Koka row polymorphic effects");
let text: String = r.value;
let sources: ProvGraph = r.prov;

emit_provenance(sources, format: ProvFormat::ProvJson);
```

Why this helps agentic coding:

- Enables audit and replay: “Which tool output led to this patch?”
- Supports supply-chain security integration and debugging of agent behavior.

### Security and sandboxing

**Default choice**: capability discipline + sandbox execution for untrusted code.

Capability-based security supports least privilege and avoids confused deputy problems. citeturn19view0 WASI positions itself as a secure standard interface for Wasm modules, enabling plugin-like composition. citeturn16view0

Proposed syntax:

```agentfp
capability Fs;
capability Net;
capability Llm;

pub fn main(caps: { fs: Fs, net: Net, llm: Llm }) -> Unit !{io} {
  // cannot access filesystem unless caps.fs is passed
  let cfg = caps.fs.read_text("config.toml")?;
  ...
}

sandbox (caps: { net }) {
  // inside sandbox: only Net capability is available
  perform net.get("https://example.com");
}
```

Optional: information-flow labels for secrets, based on language-based IFC principles.

```agentfp
type Secret<T>  // opaque wrapper tracked by the type system

pub fn use_key(k: Secret<ApiKey>) -> Unit !{net} { ... }

pub fn declassify<T>(x: Secret<T>, policy: Policy) -> T !{declassify}
```

Static IFC is motivated by surveys of security-type systems and their ability to enforce noninterference policies via typechecking. citeturn19view2

### Architecture diagram

```mermaid
flowchart TB
  subgraph Compile["Compile-time pipeline"]
    P[Parse] --> M[Macro expand (restricted)]
    M --> T[Type + effect inference]
    T --> V[Optional verification: refinements/proofs]
    V --> IR[Typed IR + provenance hooks]
    IR --> Codegen[Backends: native / wasm]
  end

  subgraph Run["Runtime (agentic execution)"]
    Loop[Agent loop: plan → act → observe] --> Tools[Typed tool adapters]
    Tools --> Prov[Provenance store (PROV/SLSA export)]
    Loop --> Eff[Effect handlers + scheduler]
    Eff --> Sand[Sandbox (Wasm/WASI) + capability gating]
    Sand --> Tools
  end
```

Core idea: the same typed interfaces serve humans, compilers, language servers, and agents, reducing ambiguity and improving automation reliability. citeturn15view0turn32view0turn12view0

## Comparative evaluation and recommended defaults

The table below compares candidate syntax choices. “Recommended” reflects the default AgentFP design proposed earlier, optimized for a balance of expressiveness, safety, learnability, toolability, and performance.

| Dimension | Candidate syntax choice | Expressiveness | Safety | Learnability | Toolability | Runtime performance | Notes / rationale |
|---|---:|---:|---:|---:|---:|---|
| Blocks | **Braces + explicit terminators** (recommended) | High | Med | High | High | High | Avoids indentation brittleness; favors stable parsing/editing; aligns with agent tooling observations. citeturn14view0 |
|  | Significant whitespace | Med | Med | High | Med | High | Human-friendly, but agents often produce whitespace bugs in surgical edits (industry observation). citeturn14view0 |
|  | S-expressions | High | Med | Med | High | High | Great for tooling; harder for LLMs to balance parentheses reliably in long diffs (observation). citeturn14view0 |
| Typing | **Static + inference; explicit public signatures** (recommended) | High | High | High | High | High | ML tradition; signatures aid local reasoning and modularity. citeturn20view0turn8search9 |
|  | Fully explicit types everywhere | Med | High | Med | High | High | Too verbose; agent and human review overhead increases. |
|  | Gradual typing default | High | Med | High | Med | Med | Useful for prototyping; complicates reasoning; best as an interop escape hatch. citeturn28view1 |
| Effects | **Row-polymorphic effects + handlers** (recommended) | High | High | Med | High | High | Koka-style explicit effects + modular handlers; strong reasoning properties. citeturn13view0turn12view3 |
|  | Monads + `do` notation | High | High | Med | High | Med | Foundational and compositional (Moggi/Wadler), but can add syntactic overhead and “plumbing.” citeturn1search0turn1search1 |
|  | Unchecked effects/exceptions | High | Low | High | Med | High | Weak interpretability; brittle under refactors; agents overcatch or miss failures. citeturn14view0 |
| Errors | **`Result` + `?` propagation** (recommended) | High | High | High | High | High | Explicit failure channel; concise propagation; strong precedent. citeturn23view0turn14view0 |
| Concurrency | **Structured concurrency** (recommended) | High | High | Med | High | High | Lifecycle/cancellation encoded in syntax; avoids orphan tasks. citeturn7search1turn7search0 |
|  | Actor model default | High | High | Med | Med | High | Great for distributed; can be heavier for local async flows; works well as library. citeturn7search3turn17view1 |
| State | **Immutable default + region/ST + STM** (recommended) | High | High | Med | High | Med | Encapsulated mutation and composable concurrency primitives. citeturn13view0turn29view0turn8search0 |
| Macros | **Restricted typed metaprogramming** (recommended) | Med | High | Med | High | High | Keeps predictability; Template Haskell shows typechecked generated code, but macro overuse harms understandability. citeturn27view0turn14view0 |
| Provenance | **Built-in provenance graph export** (recommended) | Med | High | Med | High | Med | Supports audit/replay; aligns with PROV + SLSA/in-toto provenance needs. citeturn12view4turn31view0turn31view1 |
| Sandboxing | **Wasm/WASI + capability gating** (recommended) | Med | High | Med | High | High | Secure plugin-style execution and least privilege. citeturn16view0turn19view0 |

## Minimal example program demonstrating agentic behavior

This example illustrates: explicit intent annotations, planning primitives, tool calls with typed schemas, test execution, iterative refinement, and provenance emission.

```agentfp
#[intent(
  goal: "Fix failing tests for issue #417",
  constraints: { no_api_breaks: true, sandbox_untrusted: true }
)]
pub fn fix_issue(issue: Issue, caps: { repo: RepoCap, llm: Llm, runner: TestRunner }) -> FixReport !{repo, llm, proc, prov} {
  // 1) Plan
  let plan = plan {
    step ReadFile(issue.files_hint);
    step RunTests(Impacted);
    step Summarize("Propose patch, apply, re-run until green or max_iters");
  };

  // 2) Observe current failure
  let initial = caps.runner.run_tests(issue.test_selector)?;
  if initial.passed { return FixReport::AlreadyGreen(initial); }

  // 3) Ask model for a structured patch proposal
  type PatchProposal = { diff: Patch, rationale: String };

  let prompt = prompt"""
You are a code-fixing agent.
Given failing test output and repository context, propose a minimal patch.
Return JSON matching PatchProposal.
""";

  let mut iters = 0;
  let mut last = initial;

  while iters < 5 && !last.passed {
    let proposal: PatchProposal =
      caps.llm.complete(prompt.with_context(last.output), schema_of<PatchProposal>());

    // Apply patch inside sandboxed repo operation
    sandbox (caps: { repo }) {
      caps.repo.apply_patch(proposal.diff)?;
    }

    // Re-run tests
    last = caps.runner.run_tests(issue.test_selector)?;
    iters += 1;
  }

  // 4) Emit provenance (tool calls, diffs, test runs)
  emit_provenance(current_prov_graph(), format: ProvFormat::ProvJson);

  if last.passed {
    FixReport::Fixed { iterations: iters, final_run: last }
  } else {
    FixReport::GaveUp { iterations: iters, last_run: last }
  }
}
```

Why this qualifies as “agentic behavior”:

- It is goal-directed (intent annotation + plan).
- It uses tools (test runner, repo patching) and an LLM call with schema-constrained output, aligning with tool-calling and structured-output patterns in production LLM systems. citeturn12view0turn12view1turn18view0  
- It is iterative and feedback-driven, consistent with agentic programming definitions and observed workflows in SWE-agent and surveys. citeturn12view5turn15view0  
- It produces provenance for audit/replay, aligning with PROV/SLSA/in-toto motivations. citeturn12view4turn31view0turn31view1  

## Primary sources and further reading

Agentic coding and tool integration:

- SWE-agent (agent–computer interfaces; impact of interface/tooling design). citeturn12view5turn9search0  
- ReAct (interleaving reasoning and acting; interpretable trajectories). citeturn30view2  
- OpenAI tool/function calling + structured outputs (schema-based tool IO). citeturn12view0turn12view1  
- Anthropic advanced tool use (motivation for programmatic tool calling and tool search). citeturn18view0  
- AutoGen (multi-agent frameworks; programmable conversation patterns). citeturn17view0turn17view1  
- SWE-bench and SWE-bench Verified (evaluation benchmarks and constraints; relevance of tool calling vs string parsing). citeturn30view1turn30view0  

Functional foundations: effects, modules, state, concurrency:

- Moggi (monads as a semantics of computation). citeturn1search0turn1search8  
- Wadler (monads for structuring functional programs). citeturn1search1turn1search9  
- Koka effect types (row-polymorphic effects; semantic guarantees like “no `exn` ⇒ no unhandled exception”). citeturn13view0turn1search6  
- Plotkin & Pretnar (handlers of algebraic effects). citeturn1search3turn1search7  
- OCaml effect handlers (practical language design; expressiveness for async I/O/threads). citeturn12view3turn24view1  
- Multicore OCaml experience (user-level schedulers enabled by effect handlers). citeturn24view0  
- Harris et al. STM (composability; formal semantics; retry/orElse). citeturn29view0  
- Launchbury & Peyton Jones (encapsulated local mutation; state threads). citeturn8search0turn8search15  
- Standard ML Definition + ML module system research (signatures, modularity, separate compilation). citeturn20view0turn20view1  

Verification and advanced type systems:

- Linear Haskell (linear arrows; protocols; safe mutable data behind pure interfaces). citeturn22view0  
- Liquid Types / Liquid Haskell (refinement types + inference; scalable safety proofs). citeturn10search0turn10search4turn10search5  
- F★ (dependent types + multi-monadic effects; SMT-backed verification; pay-as-you-go). citeturn21view0turn21view1  
- Idris and Lean (dependent types; elaboration and extensibility/metaprogramming). citeturn5search8turn5search1  
- Foundational proof-carrying code (auditable execution of untrusted code with minimal TCB). citeturn26view0  

Security and provenance:

- Capability-based security analysis (object capabilities; least privilege; confused deputy). citeturn19view0  
- Language-based information-flow security survey (static enforcement; labels; implicit flows). citeturn19view2  
- W3C PROV-DM provenance model. citeturn12view4  
- SLSA provenance and in-toto specification (software supply-chain integrity and audit). citeturn31view0turn31view1turn31view2  
- WASI introduction (secure standard system interface for Wasm modules). citeturn16view0  

Tooling ecosystem:

- Language Server Protocol overview/spec (standard semantic tooling interface). citeturn32view0turn32view1
