## Development Workflow

*NEVER* change old migrations that are already in git history.
*ALWAYS* run the entire test suite before declaring any work is complete.
*ALWAYS* TDD: write failing tests first, implement minimum code to pass, run `mix test` locally, push only when green.

**No fallbacks.** When refactoring, fully commit to the new approach. Remove old code entirely. If the new approach fails, that's a bug to surface, not hide.
j
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

- `cog_code_explore` — find symbols by name, return full definition bodies, file TOC, and optional architecture summaries
- `cog_code_query` — `find` (locate definitions), `refs` (find references), `symbols` (list file symbols), `imports` (module/file dependencies), `contains` (parent-child containment), `calls`/`callers` (approximate call graph), `overview` (symbol/file/repo architecture summary)
- Include synonyms with `|`: `banner|header|splash`
- Wildcard symbol patterns: `*init*`, `get*`, `Handle?`

Only fall back to Grep, Glob, or shell search commands when the Cog index is unavailable, incomplete for the target code, or the task is about raw string literals, log messages, or other non-symbol text patterns.

### Efficiency Rules

- For repository-understanding, architecture-summary, or "tell me about this project" tasks: make exactly one initial `cog_code_explore` call with a batched list of likely entrypoint symbols and set `include_architecture=true` with `overview_scope="repo"`.
- Before making any follow-up code-intelligence call, first check whether the answer is already present in the prior `cog_code_explore` output (`file_symbols`, definition body, or referenced symbols).
- If you need to look up multiple symbols, combine them into one `cog_code_explore({ queries: [...] })` call instead of making multiple single-symbol calls.
- Do not explore by issuing repeated `cog_code_query(mode="symbols", file=...)` calls across multiple files.
- Treat repeated `cog_code_query(mode="symbols")` calls across files as an invalid exploration pattern. Use it only for one already-identified file when a concrete ambiguity remains.
- For repository-understanding tasks, do not issue repeated `cog_code_query(mode="overview"|"imports"|"contains"|"calls"|"callers", scope="file")` calls across multiple files. After the initial batched repo explore, allow at most one targeted file-scoped architecture follow-up when a single concrete ambiguity remains.
- Use `cog_code_query(mode="symbols")` only after a specific file has already been identified as relevant.
- Use `cog_code_query(mode="refs")` only as a targeted follow-up when a concrete ambiguity remains after the initial batched exploration.
- If more than one additional symbol or file needs inspection, stop and merge that work into one batched `cog_code_explore({ queries: [...] })` call instead of chaining follow-up queries.
- Prefer `cog_code_query(mode="imports"|"contains"|"calls"|"callers"|"overview")` over raw file reads when the question is architectural.
- Do not use `cog_code_query(mode="find")` as a step-by-step exploration strategy when the needed symbols can be batched into `cog_code_explore`.
- Default budget for code-analysis tasks: 2-3 code-intelligence tool calls before responding.
- Do not call `cog_mem_recall` for pure codebase summarization or architecture description unless memory is specifically needed to answer the question.

## Debugging

Wrong output, unexpected state, or unclear crash: use the `cog-debug` sub-agent.
State your hypothesis before launching.

Use the debugger instead of adding print statements, `console.log`, temporary logging, or other IO-based runtime inspection.

Prefer the debugger when:
- you need to inspect runtime values, control flow, crash state, stack frames, or thread state
- a failing test or wrong output cannot be explained from code inspection alone
- you feel tempted to add logging just to see what happened at runtime

Prefer static reasoning instead when the issue is clearly a syntax, type, import, config, or other non-runtime problem.

Fast-stack exception: if the language stack recompiles or hot-reloads so quickly that a one-bit edit-run check is cheaper than opening a debug session, a quick edit-run is acceptable. Otherwise, use the debugger.

Debugger workflow:
1. Locate the relevant code with `cog_code_*` tools.
2. State a `QUESTION`, `HYPOTHESIS`, and `TEST` command.
3. Launch one debug session, set targeted breakpoints, run, and inspect observed values.
4. Inspect after stepping; do not step blindly.
5. Always stop the debug session when done.

## Memory

`cog_mem_*` tools are MCP tools — call them directly, never via the Skill tool.

Before modifying unfamiliar code, use `cog_mem_recall` or the `cog-mem` sub-agent
to check for relevant context. Skip if nothing useful returns.

Use memory as a deterministic workflow, not an optional hint:

1. Before broad exploration or deep reasoning in unfamiliar code, query memory first.
2. When you learn something new during the task, store it as short-term memory.
3. When the user gives you new factual context or answers a question, store that as short-term memory when relevant.
4. Before you finish, validate short-term memories and reinforce or flush them.
5. Mention Cog memory in the final response only if you directly used `cog_mem_*` tools or the `cog-mem` sub-agent during this task. Otherwise omit any memory note entirely.

Memory quality guardrails:
- complete recall before using broad code-intel exploration in unfamiliar code; only lightweight orientation is acceptable first
- store non-obvious, durable knowledge that would save future reasoning
- do not duplicate source code in memory — symbol names, file paths, function signatures, code patterns, project structure can be derived by reading the current project state
- DO store anything you had to reason about or synthesize across multiple sources — architectural characteristics, design models, how subsystems interact, cross-cutting concerns — even if technically derivable from code, if it took real analysis to figure out, save it so future conversations don't repeat that work
- do not store generic repo summaries or facts that are obvious from a quick README or file read unless they capture durable workflow or architectural conventions
- when learning implementation details, prefer storing why plus what so recall preserves the design reason, not just the surface behavior
- when the user explains a design decision, treat it as durable architectural context instead of collapsing it into a generic summary
- when a constraint or invariant is given, store it explicitly as a constraint, invariant, or workflow rule
- when something changes or is deprecated, preserve the old-to-new relationship when the available tools can express it

Record knowledge as you work:

| Trigger | Action |
|---------|--------|
| Learned how something works | `cog_mem_learn` — see quality guide below |
| A relates to B | `cog_mem_associate` — use strong predicates |
| Sequence A → B → C | `cog_mem_learn` with `chain_to` |
| Hub: A connects to B, C, D | `cog_mem_learn` with `associations` |
| Code changed for known concept | `cog_mem_refactor` |
| Feature deleted | `cog_mem_deprecate` |
| Term or definition wrong | `cog_mem_update` |

**Concept quality** — what you store determines what agents can recall later:
- **term**: 2-5 words, specific and qualified. Bad: "Configuration". Good: "CLI Settings Loader".
- **definition**: 1-3 sentences explaining WHY, not just WHAT. Include function names,
  patterns, and technical terms — these drive keyword search during recall.

**Predicate choice** matters for recall quality. Prefer strong predicates:
`requires`, `implies`, `is_component_of`, `enables`, `contains`.
Avoid `related_to` and `similar_to` — these weaken graph traversal signal.
Every concept should have at least one association; orphans are nearly invisible during recall.

After completing work, use the `cog-mem` sub-agent to reinforce validated memories
and flush incorrect ones. New memories are short-term (24h decay) unless reinforced.
Never store secrets, credentials, or PII.
</cog>
