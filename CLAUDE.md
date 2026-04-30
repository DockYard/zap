## No Workarounds, Hacks, or Shortcuts

**STRICTLY FORBIDDEN.** Never implement workarounds, hacks, temporary fixes, or shortcuts of any kind. Every solution must be the correct, production-grade, long-term fix — regardless of how difficult, expensive, or time-consuming it is. If a proper fix requires deep architectural changes across multiple files, that is the fix. If it requires changes to the Zig fork, make those changes. If it requires redesigning a data structure, redesign it. Cost and time are not concerns — correctness and quality are. Never choose expediency over correctness. Never paper over a root cause with a band-aid. If you find yourself writing a "temporary" fix, stop — find and implement the real solution.

## Never compromise on code quality

When you have an option to finish a taks faster but implementing a short cut, a hack, or some lower quality solution nerver take this option. Always pursure the highest quality solution regardless of the implementation cost or complexity of the solution.

## Working with our Zig fork

Zap uses a fork of Zig 0.16.0 which should be at ~/projects/zig

You have full permission to make changes to this fork if necessary to unblock work in Zap. The same code quality rules apply to our Zig fork as does this project.

When you need to compile our Zig fork consider the compilation guide in Zap's README as well as the README in our Zig for to understand how to build our Zig fork to compile Zap.

## Zap is a Language — Implement Features in Zap Code

**THIS IS THE MOST IMPORTANT RULE. VIOLATIONS ARE UNACCEPTABLE.**

Zap is a general-purpose programming language. Features, behaviors, library functions, and language constructs MUST be implemented in Zap source code (`lib/*.zap`), NOT hardcoded in the Zig compiler (`src/*.zig`).

**NEVER hardcode Zap struct names, function names, or library behavior in the compiler.** The compiler is a general-purpose tool. It does not know about IO, String, Kernel, Map, Zest, or any other Zap struct. If you find yourself writing a Zap struct name as a string literal in Zig source, you are doing it wrong. Stop. Think. Find the Zap-level solution.

**ALWAYS attempt the Zap solution first.** Before touching any Zig compiler code, ask: "Can this be done in Zap?" If the answer is "yes" or "maybe," do it in Zap. If you think it can't be done in Zap, think harder. Research how Elixir solves it. Research how other languages solve it. Only touch the compiler as a last resort for genuine language primitives (parsing, type system, ZIR emission).

**The only things that belong in Zig:**
- Lexer/parser syntax (tokens, AST nodes)
- Type system primitives (Bool, String, Atom, i64, etc.)
- ZIR emission mechanics
- Zig runtime primitives that physically cannot be expressed in Zap (stdout, OS argv, memory allocation)

**Everything else is Zap code:**
- Standard library functions (IO, String, Integer, etc.) — defined in `lib/*.zap`, call `:zig.` for primitives
- Macros (if, unless, and, or, |>, sigils) — defined in `lib/kernel.zap`
- Test framework — defined in `lib/zest/*.zap`
- Sigil implementations — defined as macros in Kernel
- Validation, error checking, behavior — Zap macros and functions

**Do not take shortcuts.** Do not bypass Zap because the Zig solution is "easier" or "faster." Do not hardcode behavior in the compiler because you can't figure out how to do it in Zap. Spend the time. Research deeply. Find the correct solution. Cost and time are not concerns — correctness is.

**Do not create unnecessary abstractions in Zig.** No `@native`, no route tables, no runtime state tracking in Zig for things that are Zap-level concerns. If something was implemented in Zig and it could be Zap, rip it out and rewrite it in Zap.

## Documentation

**All public Zap functions MUST have `@fndoc` attributes.** Every `pub fn` and `pub macro` in `lib/*.zap` files must have a `@fndoc` string describing what it does. Use heredoc `"""` for multi-line docs. No exceptions.

## Zap Code Quality

- **Blank line after every heredoc closing `"""`**. The `"""` must be followed by an empty line before the next declaration or attribute. No exceptions.
- **`@structdoc` goes inside the struct body**, immediately after `pub struct Name {`.
- **`@fndoc` goes immediately before the function/macro it documents**, with a blank line between the closing `"""` and the `pub fn`/`pub macro`.
- **All `@fndoc` and `@structdoc` use heredoc `"""`** for multi-line content.
- **Escape `#{` in doc examples** as `\#{` to prevent interpolation inside heredocs.
- **Always use descriptive names.** Never use short or cryptic variable names, parameter names, or helper names when writing new code. Prefer explicit names that make the code readable without extra context.

## Development Workflow

*NEVER* change old migrations that are already in git history.
*ALWAYS* run the entire test suite before declaring any work is complete.
*ALWAYS* TDD: write failing tests first, implement minimum code to pass, run `zig build test` locally, push only when green.

**No fallbacks.** When refactoring, fully commit to the new approach. Remove old code entirely. If the new approach fails, that's a bug to surface, not hide.

## Code Generation

**Zap ALWAYS lowers to ZIR.** The only code generation path is `src/zir_builder.zig` → C-ABI calls to the Zig fork. *NEVER* generate Zig source text files. `src/codegen.zig` is legacy dead code — do not use it, do not write tests against it, do not treat it as a working backend. If a feature cannot be expressed through the ZIR builder, the correct fix is to add the necessary C-ABI function to the Zig fork (`~/projects/zig`), not to fall back to text codegen. Integration tests must validate through the ZIR path, not by checking generated Zig source strings.

## Release Process

When the user says "release" (or similar), follow this procedure:

### 1. Determine the version

- If the user specifies a version, use it.
- *MUST* read the current version from `build.zig.zon` first and treat that source-code version as the canonical baseline for the next release. Do not derive the baseline version from git tags, commit messages, or GitHub releases when they disagree with the source tree.
- Do not bump to a new major version while the project is still on `0.x` unless the user explicitly instructs you to start a `1.x` (or higher) release. When the project is still on `0.x`, default to the appropriate `0.x` bump even if the changes would normally look "major" under full SemVer.
- Otherwise, analyze the unreleased commits since the last release commit/tag that matches the source-code version lineage and apply [Semantic Versioning](https://semver.org/):
  - **patch** (0.0.x): bug fixes, build fixes, documentation, dependency updates
  - **minor** (0.x.0): new features, new commands, non-breaking enhancements
  - **major** (x.0.0): breaking changes to CLI interface, config format, or public API
- If tags or history suggest a higher version than `build.zig.zon`, treat that as drift to be corrected instead of as the next release baseline.

### 2. Update version string

Update the version in the single source of truth:
- `build.zig.zon` — `.version = "X.Y.Z",`

(`build.zig` reads the version from `build.zig.zon` via `@import`)

### 3. Review and update README.md

Ensure the README accurately reflects the current state of the project:
- New commands or features are documented
- Removed or renamed features are cleaned up
- Installation instructions are current
- Examples and usage sections match the actual CLI interface

### 4. Update CHANGELOG.md

Follow [Keep a Changelog](https://keepachangelog.com/):
- Add a new `## [X.Y.Z] - YYYY-MM-DD` section below `## [Unreleased]` (or below the header if no Unreleased section exists)
- Categorize changes under: Added, Changed, Deprecated, Removed, Fixed, Security
- Add a link reference at the bottom: `[X.Y.Z]: https://github.com/trycog/cog-cli/releases/tag/vX.Y.Z`
- Each entry should be a concise, user-facing description (not a commit message)

### 5. Commit, tag, and push

```sh
git add build.zig.zon README.md CHANGELOG.md
git commit -m "Release X.Y.Z"
git tag vX.Y.Z
git push && git push origin vX.Y.Z
```

The GitHub Actions release workflow handles the rest: building binaries, creating the GitHub Release, and updating the Homebrew tap.

<cog>
# Cog

Code intelligence, persistent memory, and interactive debugging.

**Truth hierarchy:** Current code > User statements > Cog knowledge.

## Code Intelligence

For any request to explore, analyze, understand, map, or explain code, use `cog_code_explore` or `cog_code_query`.
Do NOT use Grep, Glob, or shell search commands like `grep`, `rg`, `find`, or `git grep` for code exploration when the Cog index is available.

- `cog_code_explore` — find symbols by name, return full definition bodies, file TOC, and optional architecture summaries. ALWAYS put all symbols into a single `queries` array — never split across multiple calls.
- `cog_code_query` — `find` (locate definitions), `refs` (find references), `symbols` (list file symbols), `imports` (struct/file dependencies), `contains` (parent-child containment), `calls`/`callers` (approximate call graph), `overview` (symbol/file/repo architecture summary). ALWAYS use the `queries` array to combine multiple queries into one call — never make sequential code_query calls that could be batched.
- Include synonyms with `|`: `banner|header|splash`
- Wildcard symbol patterns: `*init*`, `get*`, `Handle?`

Only fall back to Grep, Glob, or shell search commands when the Cog index is unavailable, incomplete for the target code, or the task is about raw string literals, log messages, or other non-symbol text patterns.

### Batching Rules

Both `cog_code_explore` and `cog_code_query` accept a `queries` array.
Making sequential calls to the same tool when a single batched call would
work is an error. Combine them.

- `cog_code_explore`: put ALL symbols into one `queries` array.
  Do not call `cog_code_explore` twice when both calls could be one.
- `cog_code_query`: put ALL queries into one `queries` array. Each entry
  specifies its own `mode`, `name`, `file`, `kind`, `direction`, `scope`.
  Example: symbols for 3 files = one call with 3 entries, not 3 calls.
- For repository-understanding tasks: one initial `cog_code_explore`
  with `include_architecture=true` and `overview_scope="repo"`, then at
  most one targeted follow-up.
- Before making follow-up calls, check whether the answer is already
  present in prior output.
- Prefer `cog_code_query` over raw file reads for architectural questions.
- Budget: 2-3 code-intelligence calls before responding.

## Debugging

**Always delegate debugging to the `cog-debug` sub-agent.** Do NOT call `cog_debug_*` tools directly from the primary agent.

When you need to investigate runtime behavior — wrong output, unexpected state, crashes, or variable inspection — delegate to the `cog-debug` sub-agent with a prompt containing:
- **QUESTION**: what you want to understand about runtime behavior
- **HYPOTHESIS**: your theory about what's happening
- **TEST**: the command or binary to run

The sub-agent handles all debugger operations: launching, breakpoints, stepping, inspection, and cleanup. It returns a concise report with observed values and a verdict.

Prefer the debugger when:
- you need to inspect runtime values, control flow, crash state, stack frames, or thread state
- a failing test or wrong output cannot be explained from code inspection alone
- you feel tempted to add logging just to see what happened at runtime

Prefer static reasoning instead when the issue is clearly a syntax, type, import, config, or other non-runtime problem.

Fast-stack exception: if the language stack recompiles or hot-reloads so quickly that a one-bit edit-run check is cheaper than opening a debug session, a quick edit-run is acceptable. Otherwise, delegate to `cog-debug`.

Do NOT fall back to shell debuggers (lldb, gdb, dlv) — the `cog-debug` sub-agent handles all debugging.

## Memory

`cog_mem_*` tools are MCP tools — call them directly, never via the Skill tool.

When you do not already know how to do something and prior knowledge may help,
delegate to the `cog-mem` sub-agent first. That specialist should attempt
memory recall, decide whether memory is sufficient, and only then escalate to
Cog code exploration if memory is insufficient. Do not launch a separate
Explore/code-research sub-agent alongside `cog-mem` for the same question.

Use memory as a deterministic workflow, not an optional hint:

1. When you do not know how to do something, delegate to `cog-mem` first so it
   can query long-term memory.
2. If long-term memory does not answer it, let `cog-mem` escalate to code
   exploration.
3. If exploration plus reasoning teaches a durable fact, workflow, constraint,
   or design reason, call `cog_mem_learn` with an `items` array.
4. During regular work, if you figure out a durable fact, call `cog_mem_learn`
   with an `items` array.
5. Before you finish, if this task created short-term memory or you explored
   code and learned something durable, delegate to `cog-mem-validate` to
   learn and consolidate in one call. Do NOT call `cog_mem_learn`,
   `cog_mem_list_short_term`, `cog_mem_reinforce`, or `cog_mem_flush` directly
   from the primary agent — always delegate to `cog-mem-validate`.
6. Mention Cog memory in the final response only if you directly used `cog_mem_*`
   tools or the `cog-mem` sub-agent during this task. Otherwise omit any memory
   note entirely.

Memory quality guardrails:
- when prior knowledge may help, do recall before broad code-intel exploration; only lightweight orientation is acceptable first
- store non-obvious, durable knowledge that would save future reasoning
- do not store generic repo summaries or facts that are obvious from a quick README or file read unless they capture durable workflow or architectural conventions
- when learning implementation details, prefer storing why plus what so recall preserves the design reason, not just the surface behavior
- when the user explains a design decision, treat it as durable architectural context instead of collapsing it into a generic summary
- when a constraint or invariant is given, store it explicitly as a constraint, invariant, or workflow rule
- when something changes or is deprecated, preserve the old-to-new relationship when the available tools can express it

**All memory tools require arrays** — `items` for learn/associate, `queries` for
recall, `engram_ids` for get/connections/reinforce/flush. Always pass an array,
even for a single entry. Gather related operations into one batched call.

Record knowledge as you work - use IF-THEN rules:

- IF you completed analysis that required reasoning across multiple symbols
  or files, THEN call `cog_mem_learn` with an `items` array immediately,
  before writing response text.
- IF you do not know how to do something and prior knowledge may help, THEN
  delegate to `cog-mem` before broad exploration.
- IF A relates to B, THEN call `cog_mem_associate` with an `items` array
  using a strong predicate.
- IF you discovered a sequence A -> B -> C, THEN call `cog_mem_learn` with
  `chain_to` in the items entry.
- IF a concept connects to multiple others, THEN call `cog_mem_learn` with
  `associations` in the items entry.
- IF you changed code for a known concept, THEN call `cog_mem_refactor`.
- IF a feature was deleted, THEN call `cog_mem_deprecate`.
- IF a term or definition is wrong, THEN call `cog_mem_update`.

**Concept quality** — what you store determines what agents can recall later:
- **term**: 2-5 words, specific and qualified. Bad: "Configuration". Good: "CLI Settings Loader".
- **definition**: 1-3 sentences explaining WHY, not just WHAT. Include function names,
  patterns, and technical terms — these drive keyword search during recall.

**Predicate choice** matters for recall quality. Prefer strong predicates:
`requires`, `implies`, `is_component_of`, `enables`, `contains`.
Avoid `related_to` and `similar_to` — these weaken graph traversal signal.
Every concept should have at least one association; orphans are nearly invisible during recall.

After completing work, delegate to `cog-mem-validate` to learn and consolidate.
New memories are short-term (24h decay) unless reinforced.
Never store secrets, credentials, or PII.

## BEFORE Responding - Memory Gate

Before writing your response to the user, verify:

1. IF prior knowledge might have helped and you never delegated to `cog-mem`
   -> do that first, then continue
2. IF you used `cog_code_explore` and learned something durable, OR this task
   created short-term memory -> delegate to `cog-mem-validate` once to learn
   and consolidate. One subagent call handles both — do not call memory
   tools directly.
3. IF you modified code for a concept that exists in memory -> call
   `cog_mem_refactor` first, then respond

If none apply, respond directly. Do not mention this checklist to the user.
</cog>
