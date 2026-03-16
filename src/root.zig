pub const Token = @import("token.zig").Token;
pub const Lexer = @import("lexer.zig").Lexer;
pub const ast = @import("ast.zig");
pub const Parser = @import("parser.zig").Parser;
pub const scope = @import("scope.zig");
pub const Collector = @import("collector.zig").Collector;
pub const MacroEngine = @import("macro.zig").MacroEngine;
pub const Desugarer = @import("desugar.zig").Desugarer;
pub const Resolver = @import("resolver.zig").Resolver;
pub const types = @import("types.zig");
pub const DispatchEngine = @import("dispatch.zig").DispatchEngine;
pub const hir = @import("hir.zig");
pub const ir = @import("ir.zig");
pub const CodeGen = @import("codegen.zig").CodeGen;
pub const runtime = @import("runtime.zig");
pub const DiagnosticEngine = @import("diagnostics.zig").DiagnosticEngine;
pub const stdlib = @import("stdlib.zig");

test {
    _ = @import("token.zig");
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
    _ = @import("parser.zig");
    _ = @import("scope.zig");
    _ = @import("collector.zig");
    _ = @import("macro.zig");
    _ = @import("desugar.zig");
    _ = @import("resolver.zig");
    _ = @import("types.zig");
    _ = @import("dispatch.zig");
    _ = @import("hir.zig");
    _ = @import("ir.zig");
    _ = @import("codegen.zig");
    _ = @import("runtime.zig");
    _ = @import("diagnostics.zig");
    _ = @import("stdlib.zig");
    _ = @import("integration_tests.zig");
}
