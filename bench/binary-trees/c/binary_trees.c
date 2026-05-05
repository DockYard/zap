// Computer Language Benchmarks Game — binary-trees, single-thread C.
// No GC; uses an arena bump allocator so the comparison against
// Zap's `page_allocator`-backed runtime is apples-to-apples.

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

typedef struct Tree Tree;
struct Tree {
    Tree *left;
    Tree *right;
};

// Arena bump allocator. Nodes are 16 bytes (two pointers); we
// allocate slabs of 64 KiB and bump within. Frees on exit only —
// matches Zap's arena-only memory model.
typedef struct Arena Arena;
struct Arena {
    char *cur;
    char *end;
    Arena *prev;
    char data[];
};

static Arena *g_arena = NULL;
static const size_t SLAB = 64 * 1024;

static void *arena_alloc(size_t n) {
    if (!g_arena || g_arena->cur + n > g_arena->end) {
        size_t cap = SLAB;
        if (n > cap) cap = n;
        Arena *a = (Arena *)malloc(sizeof(Arena) + cap);
        a->cur = a->data;
        a->end = a->data + cap;
        a->prev = g_arena;
        g_arena = a;
    }
    void *p = g_arena->cur;
    g_arena->cur += n;
    return p;
}

static Tree *make(int depth) {
    Tree *t = (Tree *)arena_alloc(sizeof(Tree));
    if (depth == 0) {
        t->left = NULL;
        t->right = NULL;
    } else {
        t->left = make(depth - 1);
        t->right = make(depth - 1);
    }
    return t;
}

static long check(const Tree *t) {
    if (t == NULL) return 0;
    return 1 + check(t->left) + check(t->right);
}

int main(int argc, char **argv) {
    // Prefer BENCH_DEPTH (the harness convention used by every peer
    // implementation). Fall back to argv[1] for ad-hoc runs.
    const char *env = getenv("BENCH_DEPTH");
    int max_depth;
    if (env && *env) {
        max_depth = atoi(env);
    } else if (argc > 1) {
        max_depth = atoi(argv[1]);
    } else {
        max_depth = 14;
    }
    int min_depth = 4;
    int stretch_depth = max_depth + 1;

    long stretch_check = check(make(stretch_depth));
    printf("stretch tree of depth %d\t check: %ld\n", stretch_depth, stretch_check);

    Tree *long_lived = make(max_depth);

    for (int depth = min_depth; depth <= max_depth; depth += 2) {
        long iterations = 1L << (max_depth - depth + 4);
        long acc = 0;
        for (long i = 0; i < iterations; i++) {
            acc += check(make(depth));
        }
        printf("%ld\t trees of depth %d\t check: %ld\n", iterations, depth, acc);
    }

    printf("long lived tree of depth %d\t check: %ld\n", max_depth, check(long_lived));
    return 0;
}
