// Computer Language Benchmarks Game — binary-trees, single-thread
// Rust. Uses `bumpalo` to mirror the C / Zig / Zap arena strategy
// — Box<Tree> would put each node on the global heap and the timing
// would mostly measure free-list contention, which isn't what
// Zap's arena-only runtime exercises.

use std::io::{BufWriter, Write};
use std::env;

struct Tree<'a> {
    left: Option<&'a Tree<'a>>,
    right: Option<&'a Tree<'a>>,
}

fn make<'a>(arena: &'a bumpalo::Bump, depth: i32) -> &'a Tree<'a> {
    if depth == 0 {
        arena.alloc(Tree { left: None, right: None })
    } else {
        let left = make(arena, depth - 1);
        let right = make(arena, depth - 1);
        arena.alloc(Tree { left: Some(left), right: Some(right) })
    }
}

fn check(t: Option<&Tree>) -> i64 {
    match t {
        None => 0,
        Some(node) => 1 + check(node.left) + check(node.right),
    }
}

fn parse_depth() -> i32 {
    env::var("BENCH_DEPTH")
        .ok()
        .and_then(|s| s.parse::<i32>().ok())
        .unwrap_or(14)
}

fn main() {
    let max_depth = parse_depth();
    let min_depth = 4;
    let stretch_depth = max_depth + 1;

    let stdout = std::io::stdout();
    let mut out = BufWriter::new(stdout.lock());

    let arena = bumpalo::Bump::new();
    let stretch_check = check(Some(make(&arena, stretch_depth)));
    writeln!(out, "stretch tree of depth {}\t check: {}", stretch_depth, stretch_check).unwrap();

    let long_lived_arena = bumpalo::Bump::new();
    let long_lived = make(&long_lived_arena, max_depth);

    let mut depth = min_depth;
    while depth <= max_depth {
        let iterations: i64 = 1i64 << (max_depth - depth + 4);
        let mut acc: i64 = 0;
        let inner_arena = bumpalo::Bump::new();
        for _ in 0..iterations {
            acc += check(Some(make(&inner_arena, depth)));
        }
        writeln!(out, "{}\t trees of depth {}\t check: {}", iterations, depth, acc).unwrap();
        depth += 2;
    }

    writeln!(out, "long lived tree of depth {}\t check: {}", max_depth, check(Some(long_lived))).unwrap();
}
