# Reduced reproducers — `src/test_reductions/`

Smallest-possible Zap programs that isolate compiler / codegen bugs.
Each file demonstrates one specific failure shape; once the
underlying bug is fixed, the file becomes a regression test that
must keep compiling and producing the documented output.

Each reproducer ships with:
* a `_expected` companion or inline `#=>` comment showing the
  intended behaviour;
* a brief comment block at the top naming the bug it targets and
  the brief / commit that diagnosed it;
* enough comments that someone reading it cold can run it through
  the compiler standalone.

Reproducers don't replace the unit suite — they're the seeds for
the unit tests that follow. After the bug is fixed, the
corresponding test belongs in the appropriate `*_test.zig` /
`zest` test file.
