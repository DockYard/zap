# Independent Validation Handoff — Zap Pure-Zig TLS 1.3 Server (Socket Phase S5)

> **You are a fresh agent with zero prior context.** Your job is to **independently
> verify** a body of work another agent claims to have completed: a pure-Zig
> TLS 1.3 **server** for the Zap language, plus its Zap-level surface and test
> coverage. **Do not trust the claims in this document.** Treat every "expected
> result" below as a claim to be reproduced. Run the commands yourself, read the
> code yourself, and reach your own verdict. If something doesn't reproduce, or
> the code doesn't do what's claimed, say so plainly — that is the point of this
> exercise. Be skeptical, be adversarial, and prioritize security correctness.

---

## 1. What Zap is (orientation)

**Zap** is an ahead-of-time (AOT) compiled, Elixir-like general-purpose
programming language with BEAM-style concurrency (lightweight processes,
message passing, supervision). It is **not** interpreted and it is **not** the
"Zap" HTTP server library for Zig — ignore anything you may know by that name.

Architecture you must understand to validate this work:

- **Zap source** (`*.zap`) is compiled to **ZIR** (Zig Intermediate
  Representation) and lowered through a **fork of the Zig 0.16 compiler**. The
  only codegen path is Zap → ZIR → the Zig fork via C-ABI. There is **no** Zig
  source-text generation.
- **Two repositories are involved:**
  - **The Zig fork:** `~/projects/zig` — a fork of Zig 0.16.0. Its standard
    library (`lib/std/…`) is where the **TLS server crypto/protocol code**
    lives (`lib/std/crypto/tls/Server.zig` etc.), because it's a natural
    extension of Zig's existing `std.crypto.tls.Client`. The fork also builds
    `libzap_compiler.a` (the ZIR backend the Zap compiler links against) and the
    `zap` compiler/runtime.
  - **The Zap project:** `/Users/bcardarella/projects/zap` — the Zap language
    implementation. Its compiler frontend is in `src/*.zig`, its runtime
    (including the socket/concurrency kernel) is in
    `src/runtime/concurrency/*.zig`, and its standard library is in
    `lib/*.zap`. The **Zap-level TLS surface** (`Tls.listen`/`accept`/…) is
    `lib/tls.zap`.
- **"Gate":** Zap's concurrency runtime is a **comptime gate** that defaults
  **OFF** (zero-cost when unused). Programs that use processes/`send_move`/etc.
  must be built **gate-ON** (`runtime_concurrency: true` in the manifest, or
  `-Druntime-concurrency=on`). This matters: the TLS *server* accepts
  connections and hands them to per-connection handler processes, so its
  end-to-end tests are **gate-ON** and are built differently (and much more
  slowly) than a plain `zap test`.

If you want deeper background, read `~/projects/zap/CLAUDE.md` and
`~/projects/zap/README.md`, but they are not required for validation.

---

## 2. What was built (the claims you are validating)

Socket phase **S5** added a **pure-Zig TLS 1.3 server** and wired it into Zap.
It was built in sub-phases S5a–S5e. The high-level claims:

1. **A pure-Zig TLS 1.3 server** in the Zig fork
   (`~/projects/zig/lib/std/crypto/tls/Server.zig`), mirroring the existing
   `Client.zig`, TLS 1.3-only, supporting **ECDSA (P-256/P-384), Ed25519, and
   RSA** server certificates, SNI/ALPN parsing, HelloRetryRequest, and
   KeyUpdate. `Client.zig`'s handshake was left untouched (no S4-client
   regression).
2. **RSASSA-PSS signing** for RSA server certs — the one piece of new low-level
   crypto — built on the fork's existing constant-time modular exponentiation,
   with base blinding and a verify-after-sign fault check.
3. **A private-key parser** (`PrivateKey.zig`) for PKCS#8 / PKCS#1 / SEC1.
4. **Memory-safety and conformance hardening** found by adversarial review
   (a pre-auth stack overflow, a compressed-EC-point acceptance leniency, an
   HRR deadlock, unbounded/malformed-input parsing, etc.).
5. **A Zap-level surface** (`~/projects/zap/lib/tls.zap`): `Tls.listen`,
   `Tls.accept`, `Tls.upgrade_server`, `TlsServerConfig`, composing with the
   existing socket runtime and the S3 acceptor/handler pattern.
6. **Comprehensive test coverage**, including the **BoGo** conformance suite
   (the BoringSSL `ssl/test/runner`, an industry-standard adversarial TLS test
   corpus that rustls/Go/s2n all run), RFC 8448 known-answer vectors, and
   OpenSSL cross-verification.

### The commits to review

**Fork (`~/projects/zig`)** — `git log --oneline` should show these at/near HEAD
(`e6ecddcf2d`):
```
e6ecddcf2d fix(crypto/tls): scrub the CertificateVerify signing-key copy in Server.init
5ac0a0801a feat(crypto/tls): TLS 1.3 server hardening — BoGo conformance green (S5c)
5809f3cc77 feat(crypto/tls): RSA server certificates — RSASSA-PSS signing (S5b)
eb12517640 test(crypto/tls): BoGo TLS conformance harness for the pure-Zig server
88b92cb655 feat(crypto/tls): TLS 1.3 server ALPN selection + negotiated-parameter accessors
9ba0e16d45 feat(crypto/tls): pure-Zig TLS 1.3 server core (S5a) + memory-safety hardening
```
**Zap (`/Users/bcardarella/projects/zap`)** — at/near HEAD (`4ad36b4`):
```
4ad36b4 example(tls): gate-ON Zap TLS 1.3 server + openssl s_client interop harness
dfc0fe3 fix(test): resolve test/zap namespace pollution blocking the gate-ON manifest
5e1b7c9 feat(socket): S5d — Zap TLS server surface (Tls.listen/accept/upgrade_server)
```

Use `git show <hash>` to inspect any commit. `git diff 9ba0e16d45~1 5ac0a0801a --
lib/std/crypto/tls/` in the fork shows the whole server implementation delta.

---

## 3. Environment & prerequisites (verify these first)

Run these and confirm they match; if anything is missing, stop and report it —
the rest depends on them.

```bash
# The Zig fork, its prebuilt compiler binary, and the Zap-backend archive:
ls -la ~/projects/zig/zig-out/bin/zig                 # the FORK zig compiler
ls -la ~/projects/zig/zig-out/lib/libzap_compiler.a   # Zap ZIR backend archive
~/projects/zig/zig-out/bin/zig version                # expect: 0.16.0

# The Zap project and its prebuilt zap compiler + LLVM deps:
ls -la /Users/bcardarella/projects/zap/zig-out/bin/zap
ls -la /Users/bcardarella/projects/zap/zap-deps/aarch64-macos-none/llvm-libs

# Host tools used by conformance/interop:
openssl version    # expect OpenSSL 3.x (real OpenSSL, e.g. 3.6.2)
go version         # expect go 1.2x (needed for BoGo runner)
```

**Standard build invocation for the Zap project** (used by several steps):
```
-Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a \
-Dllvm-lib-path=zap-deps/aarch64-macos-none/llvm-libs
```

> If the prebuilt binaries are absent, you may need to rebuild the fork and/or
> the Zap compiler. That is expensive (the fork needs an LLVM-21 prefix). Prefer
> using the prebuilt binaries above; only rebuild if forced, and say so.

---

## 4. CRITICAL gotchas (read before running anything)

These are the traps that will waste your time or mislead you if you don't know
them. They were learned the hard way.

1. **NEVER run `zig build zir-test`, and never run the full `zig build test` in
   the Zap repo.** They are extremely slow and are the human's to run. You do
   not need them for this validation.

2. **The fork's *installed* std lib is stale.** `~/projects/zig/zig-out/lib/zig/`
   is an older copy that does **not** contain `Server.zig`. The **source** lib
   `~/projects/zig/lib/` is current. Therefore:
   - To run fork std tests: `~/projects/zig/zig-out/bin/zig test <file>
     --zig-lib-dir ~/projects/zig/lib` (point at the **source** lib).
   - Any Zap-repo build that needs the fork server must resolve the fork
     **source** lib (the Zap build embeds it; `test-kernel` needs
     `--zig-lib-dir ~/projects/zig/lib`).

3. **Gate-ON manifest builds are SLOW and must run SOLO.** Building a gate-ON
   Zap program uses an **incremental daemon** that cold-compiles the full Zap
   stdlib (~5–10 minutes the first time). Running **two** such builds
   concurrently causes a `EmbeddedZigLibArchiveExtractFailed` zig-lib extraction
   race — always run one at a time. The daemon persists in
   `<zap-repo>/.zap-cache/daemon/`; nuking `~/.cache/zap` does **not** clear it.
   To distinguish "compiling" from "hung," check the daemon's CPU time:
   `ps -o cputime= -p $(pgrep -f manifest-incremental-daemon)` — rising = working.
   **Always put long gate-ON builds in the background with a hard timeout** so a
   hang can't run unbounded (a prior run hung ~85 minutes unnoticed).

4. **Gate-ON `zap run <script>` does NOT honor `-Druntime-concurrency=on`.**
   Script mode keeps the gate off. Gate-ON code must be a **manifest bin** or
   **manifest test target** (`build.zap`). `zap test <file>` also builds
   gate-OFF, so it cannot run tests that use processes.

5. **Gate-ON bin stdout is buffered and flushes at process exit, not per line.**
   If a test harness waits to see a line the server prints (e.g. a port), it may
   only see it after the server already exited. Use fixed ports + connect-retry,
   not per-line stdout parsing, for external-client harnesses.

6. **The full `test_concurrency` manifest does NOT build** — several *non-socket*
   test files collide in the global namespace (e.g. two `Signal` unions).
   Socket tests are therefore run **isolated** (one file at a time via a
   narrowed manifest glob). This is a pre-existing test-harness limitation, not a
   socket defect. See §6 for the isolation recipe.

7. **Running all six socket test files in one binary hangs** (shared global
   process registry across tests → cross-test message interference). Run socket
   gate-ON tests **one file per binary**.

---

## 5. Verification checklist — cheap/fast first

Do these in order. Each says the exact command, the claimed result, and what it
proves. **Reproduce the result; don't take it on faith.**

### V1 — Fork server unit tests (fast, ~seconds). START HERE.
```bash
cd ~/projects/zig
zig-out/bin/zig test lib/std/crypto/tls/Server_test.zig --zig-lib-dir lib
```
**Claim:** `All 52 tests passed.` These cover: PKCS#8/SEC1/PKCS#1 key parsing
(incl. RSA rejection-then-support and truncated-key typed errors), **RFC 8448
byte-exact** key schedule / server Finished / record decrypt / RSA
CertificateVerify reproduction, in-process fork-`Client`↔`Server` interop
(ECDSA/Ed25519/RSA), HRR, ALPN, and adversarial bad-paths (oversized key_share,
truncated DER, tampered Finished, no-TLS-1.3, etc.).
**What it proves:** the server handshake, key schedule, record layer, RSA-PSS
signing, and bad-path handling are correct against known-answer vectors and an
in-process real verifier. **If this doesn't say 52/52, stop and report.**

### V2 — Std crypto regression (fast). No regression to shared code.
```bash
cd ~/projects/zig
zig-out/bin/zig test lib/std/std.zig --zig-lib-dir lib \
  --test-filter "crypto.Certificate" --test-filter "crypto.tls"
```
**Claim:** `All 69 tests passed.` — includes the X.509 walker and
`Certificate.Bundle` "scan for OS-provided certificates" (parses your real OS
trust store). **Proves** the shared DER parser hardening (a fork change) did not
regress real-world certificate parsing.

### V3 — Are the RFC 8448 vectors GENUINE (not fabricated to pass)?
A faked known-answer test is worse than none. Spot-check that the test embeds the
RFC's real published constants:
```bash
cd ~/projects/zig
# The canonical SHA-256 TLS-1.3 "early secret" = HKDF-Extract(0,0):
grep -c "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a" \
   lib/std/crypto/tls/Server_test_fixtures.zig   # expect: 1
# The RFC 8448 §3 ServerHello bytes (starts 020000560303a6af06a4…):
grep -c "020000560303a6af06a4" lib/std/crypto/tls/Server_test_fixtures.zig  # expect: 1
```
Then open `lib/std/crypto/tls/Server_test.zig` and read the `RFC 8448` tests —
confirm they assert the server *produces* these bytes, not merely that a value
equals itself. Cross-reference RFC 8448 §3 if you want to be thorough.

### V4 — RSA-PSS signing cross-verified by a THIRD party (OpenSSL).
Hand-rolled RSA signing is the riskiest crypto here. Verify it independently:
generate a fresh RSA key, have the Zap server's signer sign with it, and confirm
**OpenSSL** accepts the signature. A self-contained way:
```bash
cd /tmp && rm -f v_*.pem v_*.der v_sig*.bin v_msg.bin
openssl genrsa -out v_rsa.pem 2048 2>/dev/null
openssl rsa -in v_rsa.pem -traditional -outform DER -out v_rsa_pkcs1.der 2>/dev/null
openssl rsa -in v_rsa.pem -pubout -out v_rsa_pub.pem 2>/dev/null
printf 'independent-rsa-pss-cross-verify\n' > v_msg.bin
python3 - <<'PY'
d=open('/tmp/v_rsa_pkcs1.der','rb').read()
open('/tmp/v_sign.zig','w').write(
 'const std=@import("std");\n'
 'const PK=@import("std").crypto.tls.Server.PrivateKey;\n'
 'const kd=[_]u8{'+','.join(map(str,d))+'};\n'
 'const S=[_]struct{s:std.crypto.tls.SignatureScheme,t:[]const u8}{'
 '.{.s=.rsa_pss_rsae_sha256,.t="256"},.{.s=.rsa_pss_rsae_sha384,.t="384"},.{.s=.rsa_pss_rsae_sha512,.t="512"}};\n'
 'pub fn main()!void{const m="independent-rsa-pss-cross-verify\\n";var p=std.Random.DefaultPrng.init(0xC0FFEE);'
 'const k=try PK.fromDer(&kd,.pkcs1_rsa);for(S)|c|{var b:[PK.max_signature_len]u8=undefined;'
 'const sig=try k.sign(m,&b,c.s,.{.random=p.random()});std.debug.print("SIG{s}:{x}\\n",.{c.t,sig});}}\n')
PY
~/projects/zig/zig-out/bin/zig build-exe /tmp/v_sign.zig --zig-lib-dir ~/projects/zig/lib -femit-bin=/tmp/v_sign
/tmp/v_sign 2>/tmp/v_sigs.txt
for h in 256 384 512; do
  grep "^SIG$h:" /tmp/v_sigs.txt | sed "s/^SIG$h://" | tr -d '\n' | xxd -r -p > /tmp/v_sig$h.bin
  openssl dgst -sha$h -verify /tmp/v_rsa_pub.pem -sigopt rsa_padding_mode:pss \
    -sigopt rsa_pss_saltlen:-1 -signature /tmp/v_sig$h.bin /tmp/v_msg.bin \
    && echo "  SHA$h OK" || echo "  SHA$h FAILED"
done
```
**Claim:** `Verified OK` for SHA-256/384/512. **Proves** the Zap server's RSA-PSS
signatures are wire-correct against an independent implementation.

### V5 — Cross-compile (the pure-Zig cross-everything story).
```bash
cd ~/projects/zig
for t in x86_64-linux-gnu aarch64-linux-gnu x86_64-windows-gnu; do
  zig-out/bin/zig test --test-no-exec -target $t \
    lib/std/crypto/tls/Server_test.zig --zig-lib-dir lib \
    && echo "  $t OK" || echo "  $t FAILED"
done
```
**Claim:** all three compile clean. (wasm32-wasi fails only on the *test
harness*'s `std.Thread.spawn`, not the server code — a known limitation; you can
confirm the error is in `std/Thread.zig`, not `Server.zig`.)

### V6 — BoGo conformance (the industry-standard adversarial suite).
Needs `go`. Fetches the pinned BoringSSL runner
(`rustls/boringssl.git @ b6a09c71d983cf1ad7b729a7b1b287064bc6fae0`) on demand
into a gitignored `.cache/`, builds a Zig **shim** over `tls.Server`, and runs
the TLS 1.3 server corpus.
```bash
cd ~/projects/zig
./tools/bogo/run.sh 2>&1 | tail -12    # first run is slow (fetch+build); solo
```
**Claim:** `PASSED : 115` / `FAILED : 0`, exit 0, all `DisabledTests` skips
carry a justification. Read `tools/bogo/config.json` `_scope_notes` and
`_error_map_notes` — confirm the skip-list (0-RTT, resumption, client-auth,
TLS ≤ 1.2, unimplemented KEM groups) is honest and the `ErrorMap` maps each
BoringSSL error token to an RFC-8446-defensible alert, not a paper-over.
**This is the strongest single security claim** — 115 adversarial TLS 1.3 server
cases driven by a real BoringSSL client, zero failures. Verify the number
yourself, and confirm `-include-disabled` doesn't reveal a disabled test that
would actually pass (over-skipping):
```bash
# (Optional, slower) confirm no over-skipping:
grep -A50 '"DisabledTests"' tools/bogo/config.json | head -60
```

### V7 — Gate-ON end-to-end flagship (Zap client ↔ Zap server). EXPENSIVE (~10 min, SOLO).
This is the definitive gate-ON integration proof: N concurrent Zap TLS clients
handshake with the Zap TLS server, each connection is `send_move`'d to a
per-connection handler process, records flow both ways, teardown is leak-exact.
```bash
cd /Users/bcardarella/projects/zap
# Isolate: narrow the manifest to just the TLS server test, clear cache, run SOLO.
cp build.zap /tmp/build.zap.bak
sed -i.bak 's#paths: \["test_concurrency/\*\*/\*_test.zap"\]#paths: ["test_concurrency/tls_server_test.zap"]#' build.zap
rm -f build.zap.bak; rm -rf ~/.cache/zap
# Run in the background with a hard timeout; do NOT start any other build meanwhile.
ZAP_LIB_DIR=$PWD/lib timeout 1200 zig-out/bin/zap run test_concurrency \
  -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a \
  -Dllvm-lib-path=zap-deps/aarch64-macos-none/llvm-libs 2>&1 | tail -6
cp /tmp/build.zap.bak build.zap   # RESTORE build.zap when done
```
**Claim:** `2 tests, 0 failures / 10 assertions, 0 failures`. Read the two tests
in `test_concurrency/tls_server_test.zap` (the `describe(...)` at ~line 256) to
confirm they are what they claim (concurrent handshakes + `send_move` handoff +
multi-message + leak-exact via `Socket.live_count()`).
> If you see `does not match file path` (DiscoveryError) or a `transform.zap`
> type error, your tree is missing the `dfc0fe3` namespace fix — check
> `git log --oneline | grep dfc0fe3`.

### V8 — Real OpenSSL client against the LIVE Zap server. EXPENSIVE (~10 min, SOLO).
A third, independent TLS client (OpenSSL) against the full Zap server stack.
```bash
cd /Users/bcardarella/projects/zap/examples/tls_server
# Build+launch the gate-ON server bin (fixed port 44330), background it:
ZAP_LIB_DIR=/Users/bcardarella/projects/zap/lib \
  timeout 1000 /Users/bcardarella/projects/zap/zig-out/bin/zap run tls_server \
  -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a \
  -Dllvm-lib-path=zap-deps/aarch64-macos-none/llvm-libs > /tmp/v_srv.out 2>&1 &
# Retry openssl until the server is up (build is cold), then check the echo:
for i in $(seq 1 180); do
  R=$(printf 'validation-echo\n' | timeout 15 openssl s_client -connect 127.0.0.1:44330 \
        -tls1_3 -servername localhost -alpn http/1.1 -quiet 2>/tmp/v_ossl.err)
  echo "$R" | grep -q validation-echo && { echo "OPENSSL PASS: $R"; break; }
  grep -qiE "error:|BackendError|does not match" /tmp/v_srv.out && { echo "SERVER BUILD FAILED"; break; }
  sleep 5
done
grep -iE "New,|Protocol|Cipher|Verify" /tmp/v_ossl.err | head
pkill -f "zap run tls_server"
```
**Claim:** `OPENSSL PASS: validation-echo` — OpenSSL 3.x completes a TLS 1.3
handshake against the Zap server and the payload is echoed back. `verify
error:num=18:self-signed certificate` is **expected** (the fixture cert is
self-signed; `s_client` warns but completes).

---

## 6. Security review pointers (read the code, don't just run tests)

Independent code review matters as much as the tests. Prioritize:

- **`~/projects/zig/lib/std/crypto/tls/Server.zig`** — the whole server.
  Scrutinize:
  - `init` (~line 150): entropy slicing (must not overlap), cert/key validation,
    downgrade rejection (must be TLS 1.3-only), **HRR bounded to exactly one
    round**.
  - **ClientHello parsing** (`parseClientHello`, `readClientHello`): every
    length field must be bounds-checked before slicing (a lying length must
    yield a typed error, never OOB). This is the pre-auth hostile-input surface.
    A **stack buffer overflow via an oversized `key_share`** was found and fixed
    here — confirm the guard exists (`key.len > …buf.len → illegal_parameter`).
  - **Record layer** (`prepareCiphertextRecord`, `readIndirect`, `xorIvSeq`,
    `sendEncryptedFlight`, `readVerifyClientFinished`): the server must **encrypt
    with the server key/IV and decrypt with the client key/IV** (the mirror of
    `Client.zig`), nonce = IV XOR big-endian seq, seq counters never reuse a
    nonce, Finished compared with `crypto.timing_safe.eql`.
  - **CertificateVerify signing**: the signed message must be exactly
    `0x20×64 ++ "TLS 1.3, server CertificateVerify\x00" ++ transcript_hash`.
  - **Compressed-EC-point rejection** in `ServerKeyShare.respond` (TLS 1.3
    requires uncompressed `0x04` points).
  - `e6ecddcf2d` scrubs the private-key working copy after signing.
- **`~/projects/zig/lib/std/crypto/tls/PrivateKey.zig`** — RSA-PSS (`signRsaPss`,
  `rsaModExpBlinded`): EMSA-PSS per RFC 8017 §9.1.1, secret exponent via the
  **constant-time** `ff.Modulus.pow`, base blinding, verify-after-sign,
  CSPRNG-sourced salt (fail-closed). Confirm no secret-dependent branching.
- **`~/projects/zig/lib/std/crypto/tls/Client.zig`** should be **unchanged** in
  its handshake path (only shared bounds-safety fixes). Verify `git diff` on it
  is minimal and defensive-only.
- **Zap side:** `src/runtime/concurrency/socket_io.zig` (the `TlsSession`
  client/server union, the server-handshake trampoline, `zeroizeSecrets`,
  private-key confinement to the per-listener config), `abi.zig` (ownership
  gates on `zap_socket_tls_listen/_accept/_server_upgrade`, exactly-once fd
  close), and `lib/tls.zap` (the surface). Look for: the long-lived private key
  must **never** be copied into a per-connection session; the fd + TLS session
  must be closed/freed **exactly once** across every crash/kill window; the
  handshake must be DoS-bounded (deadline + per-quantum kill flag).

Approaches to consider: feed the server malformed ClientHellos; check for any
path that accepts a downgrade, a duplicate extension, an unbounded resource, or a
secret-dependent branch; confirm the BoGo skip-list hides nothing real.

---

## 7. Known limitations / deferred items (do NOT flag these as failures)

- **Multi-SNI cert selection** is single-cert only (needs a fork cert-selection
  hook). SNI is *parsed*; per-host cert *selection* is deferred.
- **tlsfuzzer** and **TLS-Anvil** were not run (BoGo 115/0 is the adversarial
  coverage that landed).
- **The full `test_concurrency` manifest does not build** (non-socket namespace
  collisions). Socket tests run isolated — expected.
- **wasm32-wasi** does not build the socket layer (64-bit atomics) / the test
  harness (threads) — pre-existing, non-server.
- Two Zap **compiler-DX** quirks were surfaced but not fixed: a recursive
  `Nil`-returning helper in a gate-ON *bin* trips `@TypeOf(null) depends on
  runtime control flow` (works in a *test* context); and the compiler silently
  allows two same-named `protocol`s from different files (the root of the
  namespace-pollution blocker). These are orthogonal to the TLS server.

---

## 8. How to reach a verdict

Weight your conclusion by what each check proves:

- **Must-pass, fast:** V1 (52/52), V2 (69/69), V3 (vectors genuine), V4 (OpenSSL
  cross-verify). If any of these fail or the vectors are fabricated, the
  implementation is not trustworthy — report immediately.
- **Strongest security evidence:** V6 (BoGo 115/0, honest skip-list). Reproduce
  the count and audit the skip-list yourself.
- **End-to-end gate-ON integration:** V7 (flagship) and V8 (OpenSSL live). These
  are slow; run them SOLO with timeouts.
- **Code review** (§6) is not optional — the tests can pass while a subtle
  security property is wrong. Read the hostile-input parsing, the record-layer
  key roles, and the RSA signing yourself.

State clearly: what you reproduced, what you couldn't (and why), any claim that
did **not** hold, and any security concern you found that the tests miss. If you
cannot run an expensive step, say so rather than assuming it passes.

Good luck — and be skeptical.
