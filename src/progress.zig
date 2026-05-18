const builtin = @import("builtin");
const std = @import("std");

const default_terminal_columns: usize = 100;
const minimum_terminal_columns: usize = 20;

/// Small stderr progress surface for the Zap CLI.
///
/// Zap owns the build-planning/frontend progress line, while the Zig fork can
/// take over with native `std.Progress` during the final embedded update. This
/// reporter keeps Zap's side single-line, width-bounded, and TTY-gated so
/// progress never wraps into persistent terminal noise.
pub const Reporter = struct {
    root_name: []const u8,
    enabled: bool,
    terminal_columns: usize,
    started: bool = false,
    line_active: bool = false,

    pub fn init(root_name: []const u8, enabled: bool) Reporter {
        return initWithColumns(root_name, enabled, detectTerminalColumns());
    }

    pub fn initWithColumns(root_name: []const u8, enabled: bool, terminal_columns: usize) Reporter {
        return .{
            .root_name = root_name,
            .enabled = enabled,
            .terminal_columns = normalizeTerminalColumns(terminal_columns),
        };
    }

    pub fn begin(self: *Reporter) void {
        if (!self.enabled or self.started) return;
        std.debug.print("{s}\n", .{self.root_name});
        self.started = true;
    }

    pub fn stage(self: *Reporter, comptime format: []const u8, args: anytype) void {
        self.stagePrefixed("", format, args);
    }

    pub fn stagePrefixed(
        self: *Reporter,
        prefix: []const u8,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (!self.enabled) return;
        self.begin();

        var message_buffer: [4096]u8 = undefined;
        const message = formatStageMessage(&message_buffer, prefix, format, args);

        var line_buffer: [512]u8 = undefined;
        const line = formatVisibleLine(&line_buffer, self.terminal_columns, message);

        std.debug.print("\r\x1b[K{s}", .{line});
        self.line_active = true;
    }

    pub fn clearLine(self: *Reporter) void {
        if (!self.enabled or !self.line_active) return;
        std.debug.print("\r\x1b[K", .{});
        self.line_active = false;
    }

    pub fn event(self: *Reporter, comptime format: []const u8, args: anytype) void {
        if (!self.enabled) return;
        self.clearLine();
        std.debug.print(format, args);
    }

    pub fn commitLine(self: *Reporter) void {
        if (!self.enabled or !self.line_active) return;
        std.debug.print("\n", .{});
        self.line_active = false;
    }

    pub fn finish(self: *Reporter) void {
        self.clearLine();
    }
};

fn detectTerminalColumns() usize {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return default_terminal_columns;

    var winsize: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const rc = std.c.ioctl(std.c.STDERR_FILENO, std.c.T.IOCGWINSZ, &winsize);
    if (rc == 0 and winsize.col > 0) return winsize.col;
    return default_terminal_columns;
}

fn normalizeTerminalColumns(columns: usize) usize {
    if (columns == 0) return default_terminal_columns;
    return @max(columns, minimum_terminal_columns);
}

fn formatStageMessage(
    buffer: []u8,
    prefix: []const u8,
    comptime format: []const u8,
    args: anytype,
) []const u8 {
    var len: usize = 0;
    if (prefix.len > 0) {
        appendBounded(buffer, &len, prefix);
        appendBounded(buffer, &len, ": ");
    }

    const written = std.fmt.bufPrint(buffer[len..], format, args) catch {
        appendBounded(buffer, &len, "<progress message too long>");
        return buffer[0..len];
    };
    len += written.len;
    return buffer[0..len];
}

fn formatVisibleLine(buffer: []u8, terminal_columns: usize, message: []const u8) []const u8 {
    const max_visible_columns = normalizeTerminalColumns(terminal_columns) - 1;
    var len: usize = 0;
    appendBounded(buffer, &len, "  ");

    const available_message_columns = if (max_visible_columns > len)
        max_visible_columns - len
    else
        0;
    if (available_message_columns == 0) return buffer[0..len];

    if (message.len <= available_message_columns) {
        appendBounded(buffer, &len, message);
    } else if (available_message_columns > 3) {
        appendBounded(buffer, &len, message[0 .. available_message_columns - 3]);
        appendBounded(buffer, &len, "...");
    } else {
        appendBounded(buffer, &len, message[0..available_message_columns]);
    }
    return buffer[0..len];
}

fn appendBounded(buffer: []u8, len: *usize, text: []const u8) void {
    if (len.* >= buffer.len) return;
    const copied_len = @min(text.len, buffer.len - len.*);
    @memcpy(buffer[len.*..][0..copied_len], text[0..copied_len]);
    len.* += copied_len;
}

test "formatVisibleLine leaves margin for terminal wrap" {
    var buffer: [64]u8 = undefined;
    const line = formatVisibleLine(&buffer, 20, "Frontend: [arc final verify 2560/2617] VeryLongFunctionName");

    try std.testing.expect(line.len <= 19);
    try std.testing.expect(std.mem.startsWith(u8, line, "  "));
    try std.testing.expect(std.mem.endsWith(u8, line, "..."));
}

test "formatStageMessage prefixes scoped stages" {
    var buffer: [128]u8 = undefined;
    const message = formatStageMessage(&buffer, "Frontend", "[hir {d}/{d}] {s}", .{ 3, 10, "TestRunner" });

    try std.testing.expectEqualStrings("Frontend: [hir 3/10] TestRunner", message);
}
