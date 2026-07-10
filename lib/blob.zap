@doc = """
  `Blob` — the one sanctioned shared value of Zap's process isolation
  model: an atomically-refcounted, deeply immutable, opaque byte buffer
  shared BY POINTER across processes.

  ## Why an exception to isolation exists

  Zap processes share nothing: every message is deep-copied (or, when
  provably unique, moved) so no two processes ever touch the same
  mutable cell, and ordinary reference counts stay non-atomic and
  scheduler-local. That model is exactly right for structured data —
  and exactly wrong for LARGE immutable payloads (file contents,
  network buffers, lookup tables, configuration) whose copy cost
  dominates. Every production actor system converged on the same
  escape hatch: Erlang shares large binaries globally behind an atomic
  refcount, Pony shares deeply immutable `val` data, BEAM ships
  `persistent_term`. `Blob` is Zap's version, in its most bounded
  form:

  * **Deeply immutable.** The bytes are copied IN exactly once, at
    `Blob.new`, and can never be mutated — there is no write API. With
    no writes there can be no cross-process data race, which is what
    makes the sharing safe.
  * **Shared by pointer.** `Process.send(pid, blob)` bit-copies the
    one-word handle and atomically increments the blob's share count.
    Zero payload bytes are copied, for any blob size, same-model or
    cross-model (the payload lives in its own allocation domain,
    outside every process heap).
  * **Lifetime beyond any one process.** The atomic count is the only
    owner. A process that dies — cleanly or by crash — merely drops
    the references it holds; a receiver's blob outlives its dead
    sender, and the payload is freed exactly when the LAST holder
    lets go.
  * **The only atomic refcount in Zap.** The atomicity is confined to
    the blob's own share count; every ordinary value keeps its cheap
    non-atomic ARC. Sharing any other value across processes remains
    impossible by construction.

  ## Ownership model

  A `Blob` value is a plain one-word handle (like a `Pid`) — copying
  it WITHIN a process is free and does not touch the count. What the
  count tracks is per-process ACQUISITIONS: `Blob.new`, receiving a
  blob message, and `Blob.get_global` each grant the calling process
  one owned reference. A process releases a reference explicitly with
  `Blob.release`, and every reference it still holds at exit is
  released automatically by the runtime — so short-lived processes
  never need to release by hand, while long-lived servers processing
  many blobs should release promptly to keep memory bounded.

  Sending a blob does NOT give up the sender's reference (the receiver
  gets its own); `Process.send_move(pid, blob)` sends AND releases the
  sender's reference in one step. Using a handle after releasing it —
  or a handle this process never acquired — panics loudly; it can
  never corrupt memory (handles are generation-validated against the
  blob table, never raw pointers).

  ## No sub-blob aliasing — slices copy out

  `Blob.slice` and `Blob.to_string` COPY the requested bytes out; a
  slice is never a view into its parent. This is a deliberate,
  evidence-backed rule: Erlang's sub-binaries pinning huge parent
  binaries is the notorious "binary leak" pathology, and Java shared
  substring backing arrays until real deployments forced the switch
  to copy-out (Swift's `String`/`Substring` split enforces the same
  at the type level). In Zap a 20-byte slice of a 10 MB blob can
  never pin those 10 MB — by construction. An explicit opt-in
  aliasing view for zero-copy networking is a documented follow-on,
  not the default.

  ## What can travel where

  A `Blob` is sendable as a TOP-LEVEL message only: `Process.send(pid,
  blob)` with a `Pid(Blob)` works; a blob nested inside a `List`, a
  `Map`, or a struct payload is a compile error in v1 (a copied
  payload cannot carry the blob's atomic reference safely through
  dead-letter and teardown paths). Send the blob as its own message.

  ## The global registry (`persistent_term` analogue)

  `Blob.put_global`/`Blob.get_global` form a global, runtime-owned
  atom-key → blob table for read-mostly data every process needs —
  configuration, dispatch tables, precomputed lookup data — so such
  data is fetched on demand instead of being mailed to every process.
  `get_global` is a lock-free read plus an atomic retain; `put_global`
  on an existing key REPLACES, and the old value is freed when its
  last outside holder drops (immutability + counting make replacement
  safe with no copy-on-update). The registry survives process churn:
  the putting process may die immediately and every later `get_global`
  still succeeds. Registry entries are released at runtime shutdown.

  ## The reserved field name

  The handle field `zap_blob_handle` is RESERVED: the runtime
  recognizes the blob handle by this exact one-field shape at process
  boundaries. Do not declare a `zap_blob_handle :: u64` field in your
  own structs.

  ## Availability

  `Blob` requires the concurrency runtime (`runtime_concurrency:
  true` in the `Zap.Manifest`) — it exists to be shared across
  processes. Gate-off binaries carry none of its runtime (zero cost)
  and using it there is a compile error.

  ## Examples

      config = Blob.new("shared configuration bytes")
      Blob.size(config)                  # => 26
      Blob.at(config, 0)                 # => 115 ('s')

      child = (Pid.of(Process.spawn(&Worker.run/0)) :: Pid(Blob))
      Process.send(child, config)        # zero-copy share
      Blob.release(config)               # our reference; the child's survives

      Blob.put_global(:app_config, Blob.new("v2"))
      fallback = Blob.new("unset")
      Blob.to_string(Blob.get_global(:app_config, fallback))   # => "v2"

  """

pub struct Blob {
  zap_blob_handle :: u64

  @doc = """
    Creates a blob by copying the string's bytes into the blob domain —
    the ONE copy of the blob's life; every share afterwards is
    zero-copy. The calling process owns one reference to the result
    (released by `Blob.release` or automatically at process exit).

    ## Examples

        blob = Blob.new("hello")
        Blob.size(blob)   # => 5

    """

  pub fn new(s :: String) -> Blob {
    %Blob{zap_blob_handle: :zig.BlobRuntime.create(s)}
  }

  @doc = """
    Returns the blob's payload length in bytes.

    Panics when the calling process does not own a reference to the
    blob (released or stale handle).

    ## Examples

        Blob.size(Blob.new("hello"))   # => 5
        Blob.size(Blob.new(""))        # => 0

    """

  pub fn size(b :: Blob) -> i64 {
    :zig.BlobRuntime.size(b.zap_blob_handle)
  }

  @doc = """
    Returns the byte at the zero-based `index` as an integer (0–255).

    Panics when the index is out of bounds, or when the calling
    process does not own a reference to the blob.

    ## Examples

        blob = Blob.new("AB")
        Blob.at(blob, 0)   # => 65
        Blob.at(blob, 1)   # => 66

    """

  pub fn at(b :: Blob, index :: i64) -> i64 {
    :zig.BlobRuntime.byte_at(b.zap_blob_handle, index)
  }

  @doc = """
    Copies the WHOLE payload out into a fresh process-owned `String`.

    The copy-out is deliberate: the returned string's lifetime is this
    process's own, fully decoupled from the blob — releasing the blob
    afterwards never invalidates the string.

    ## Examples

        blob = Blob.new("hello")
        Blob.to_string(blob)   # => "hello"

    """

  pub fn to_string(b :: Blob) -> String {
    :zig.BlobRuntime.to_string(b.zap_blob_handle)
  }

  @doc = """
    Copies the byte range `[start, start + len)` out into a FRESH blob.

    A slice is never an aliasing view into its parent — the anti-pin
    rule (see the struct doc): a small slice can never keep a huge
    parent blob alive. The new blob is an independent acquisition with
    its own reference; releasing the parent leaves it untouched.

    Panics when the range is out of bounds, or when the calling
    process does not own a reference to the blob.

    ## Examples

        blob = Blob.new("hello world")
        Blob.to_string(Blob.slice(blob, 0, 5))   # => "hello"

    """

  pub fn slice(b :: Blob, start :: i64, len :: i64) -> Blob {
    %Blob{zap_blob_handle: :zig.BlobRuntime.slice(b.zap_blob_handle, start, len)}
  }

  @doc = """
    Releases the calling process's owned reference to the blob early.
    The payload is freed when the LAST reference anywhere drops.

    Optional for short-lived processes — every reference still held at
    process exit is released automatically. Long-lived processes that
    acquire many blobs should release promptly.

    Panics when this process owns no reference (a double release, or a
    blob it never acquired). Using the handle after releasing it also
    panics — never corrupts memory.

    ## Examples

        blob = Blob.new("transient")
        _done = Blob.release(blob)

    """

  pub fn release(b :: Blob) -> Bool {
    :zig.BlobRuntime.release(b.zap_blob_handle)
  }

  @doc = """
    Returns the blob's current share count — how many owned references
    exist across all processes, in-flight messages, and the global
    registry. Advisory under concurrency (another process may retain
    or release concurrently); exact when the holders are quiescent.
    Intended for tests and diagnostics.

    ## Examples

        blob = Blob.new("counted")
        Blob.ref_count(blob)   # => 1

    """

  pub fn ref_count(b :: Blob) -> i64 {
    :zig.BlobRuntime.ref_count(b.zap_blob_handle)
  }

  @doc = """
    Returns an opaque identity token for the blob's payload buffer.
    Two blobs with equal tokens share the SAME bytes in memory — the
    zero-copy witness: send a blob to another process along with its
    identity, and the receiver's `Blob.identity` returns the same
    token, proving no byte was copied. Intended for tests and
    diagnostics; the token is meaningless beyond equality comparison
    within one run.

    ## Examples

        blob = Blob.new("witness")
        Blob.identity(blob) == Blob.identity(blob)   # => true

    """

  pub fn identity(b :: Blob) -> u64 {
    :zig.BlobRuntime.identity(b.zap_blob_handle)
  }

  @doc = """
    Returns the number of blobs currently alive in the whole runtime —
    the leak-exactness observability surface: after every holder
    releases (or dies) and the registry is empty, this returns to its
    baseline. Intended for tests and diagnostics.

    ## Examples

        base = Blob.live_count()
        blob = Blob.new("temporary")
        _released = Blob.release(blob)
        Blob.live_count() == base   # => true

    """

  pub fn live_count() -> i64 {
    :zig.BlobRuntime.live_count()
  }

  @doc = """
    Stores the blob under an atom key in the global immutable registry
    (Zap's `persistent_term` analogue — see the struct doc). The
    registry holds its own reference, so the value survives the
    putting process's death; the caller keeps its reference too.

    A put on an existing key REPLACES it: readers holding the old
    value keep it alive until they release, and the old payload is
    freed with its last holder — replacement is safe with no
    copy-on-update.

    Panics when the calling process does not own a reference to the
    blob, or when the registry is full.

    ## Examples

        _stored = Blob.put_global(:app_config, Blob.new("config v1"))

    """

  pub fn put_global(key :: Atom, b :: Blob) -> Bool {
    :zig.BlobRuntime.registry_put(key, b.zap_blob_handle)
  }

  @doc = """
    Looks the atom key up in the global immutable registry — the
    Elixir `:persistent_term.get(key, default)` shape. When the key is
    present, returns its blob and grants the calling process one owned
    reference (released by `Blob.release` or automatically at exit);
    when absent, returns `default` AS-IS (no new reference is granted —
    the caller's ownership of `default` is unchanged). Distinguish the
    two by identity when it matters: `Blob.identity(got) ==
    Blob.identity(default)` means the key was absent (or stored that
    very blob). Use `Blob.has_global?` for a pure existence probe.

    The hit path is lock-free: a read plus an atomic retain, safe
    against concurrent `Blob.put_global` replacement from any process.

    See `Blob.fetch_global/1` for the `Option(Blob)`-returning
    companion when the caller has no natural fallback blob.

    ## Examples

        fallback = Blob.new("unset")
        config = Blob.get_global(:app_config, fallback)
        Blob.to_string(config)

    """

  pub fn get_global(key :: Atom, default :: Blob) -> Blob {
    case :zig.BlobRuntime.registry_get(key) {
      0 -> default
      bits -> %Blob{zap_blob_handle: bits}
    }
  }

  @doc = """
    Looks up a blob in the global immutable registry, distinguishing
    presence from absence in the type: returns `Option.Some(blob)`
    when the atom key holds a value and `Option.None` when it does
    not. The `Option(Blob)` companion to `Blob.get_global/2` for
    callers that have no natural fallback blob.

    Present-vs-absent is decided ATOMICALLY by the same lock-free
    registry read `get_global` uses — there is no separate existence
    probe, so a concurrent `Blob.put_global` cannot slip between the
    check and the fetch. On a hit the caller receives a NEW reference
    (released by `Blob.release` or automatically at exit), exactly as
    with `get_global`.

    ## Examples

        case Blob.fetch_global(:app_config) {
          Option.Some(config) -> Blob.to_string(config)
          Option.None -> "unset"
        }

    """

  pub fn fetch_global(key :: Atom) -> Option(Blob) {
    case :zig.BlobRuntime.registry_get(key) {
      0 -> Option(Blob).None
      bits -> Option(Blob).Some(%Blob{zap_blob_handle: bits})
    }
  }

  @doc = """
    Returns `true` when the atom key currently holds a value in the
    global immutable registry. A momentary probe: a concurrent
    `Blob.put_global` may change the answer immediately after (there
    is no erase, so `true` is stable once any put happened).

    ## Examples

        Blob.has_global?(:never_put)   # => false

    """

  pub fn has_global?(key :: Atom) -> Bool {
    case :zig.BlobRuntime.registry_get(key) {
      0 -> false
      bits -> :zig.BlobRuntime.release(bits)
    }
  }
}
