const builtin = @import("builtin");
const std = @import("std");

const default_terminal_columns: usize = 100;
const minimum_terminal_columns: usize = 20;
const max_progress_nodes: usize = 128;
const max_render_depth: usize = 16;

comptime {
    if (max_progress_nodes > std.math.maxInt(u8) + 1) {
        @compileError("progress node ids store their array index in u8");
    }
}

pub const ProgressError = error{
    InvalidProgressNode,
    ProgressNodeCapacityExceeded,
    ActiveProgressChildren,
};

pub const NodeStatus = enum {
    active,
    succeeded,
    failed,
    skipped,
    cancelled,
};

pub const NodeResult = enum {
    succeeded,
    failed,
    skipped,
    cancelled,
};

pub const CacheEventKind = enum {
    hit,
    miss,
};

pub const NodeOptions = struct {
    estimated_total: ?usize = null,
};

pub const ExternalOutputHandoff = enum {
    clear,
    commit,
};

/// Stable handle for a semantic progress node.
///
/// The generation disambiguates a reused fixed-capacity slot from an older
/// completed node that previously occupied the same index.
pub const NodeId = struct {
    index: u8,
    generation: u32,
};

pub const CacheEvent = struct {
    kind: CacheEventKind,
    label: []const u8,
    item: []const u8,
};

pub const EventSink = struct {
    context: *anyopaque,
    stageFn: *const fn (context: *anyopaque, message: []const u8) void,
    outputFn: *const fn (context: *anyopaque, message: []const u8) void,
    beginFn: *const fn (context: *anyopaque, parent_id: NodeId, node_id: NodeId, label: []const u8, options: NodeOptions) void,
    updateLabelFn: *const fn (context: *anyopaque, node_id: NodeId, label: []const u8) void,
    updateCurrentItemFn: *const fn (context: *anyopaque, node_id: NodeId, current_item: []const u8) void,
    setCompletedCountFn: *const fn (context: *anyopaque, node_id: NodeId, completed_count: usize) void,
    completeOneFn: *const fn (context: *anyopaque, node_id: NodeId) void,
    finishFn: *const fn (context: *anyopaque, node_id: NodeId, result: NodeResult) void,
    cacheEventFn: *const fn (context: *anyopaque, node_id: NodeId, kind: CacheEventKind, label: []const u8, item: []const u8) void,
};

pub const NodeSnapshot = struct {
    id: NodeId,
    parent: ?NodeId,
    label: []const u8,
    current_item: []const u8,
    estimated_total: ?usize,
    completed_count: usize,
    active_child_count: usize,
    status: NodeStatus,
    cache_hits: usize,
    cache_misses: usize,
    last_cache_event: ?CacheEvent,
};

const NodeState = struct {
    in_use: bool = false,
    parent: ?NodeId = null,
    generation: u32 = 0,
    label: []const u8 = "",
    current_item: []const u8 = "",
    estimated_total: ?usize = null,
    completed_count: usize = 0,
    active_child_count: usize = 0,
    status: NodeStatus = .active,
    cache_hits: usize = 0,
    cache_misses: usize = 0,
    last_cache_event: ?CacheEvent = null,

    fn init(parent: ?NodeId, generation: u32, label: []const u8, estimated_total: ?usize) NodeState {
        return .{
            .in_use = true,
            .parent = parent,
            .generation = generation,
            .label = label,
            .estimated_total = estimated_total,
        };
    }
};

/// Allocation-free state core for scoped progress nodes.
///
/// Labels and current item slices are stored without copying. Callers must keep
/// those slices valid until they update the field again or finish the node.
pub const Manager = struct {
    nodes: [max_progress_nodes]NodeState,
    next_generation: u32,
    active_node: NodeId,

    pub fn init(root_label: []const u8) Manager {
        const root_id: NodeId = .{ .index = 0, .generation = 1 };
        var manager = Manager{
            .nodes = [_]NodeState{.{}} ** max_progress_nodes,
            .next_generation = 2,
            .active_node = root_id,
        };
        manager.nodes[0] = NodeState.init(null, root_id.generation, root_label, null);
        return manager;
    }

    pub fn rootId(self: *const Manager) NodeId {
        _ = self;
        return .{ .index = 0, .generation = 1 };
    }

    pub fn activeNodeId(self: *const Manager) NodeId {
        return self.active_node;
    }

    pub fn snapshot(self: *const Manager, node_id: NodeId) ?NodeSnapshot {
        const node_state = self.nodeStateConst(node_id) orelse return null;
        return .{
            .id = node_id,
            .parent = node_state.parent,
            .label = node_state.label,
            .current_item = node_state.current_item,
            .estimated_total = node_state.estimated_total,
            .completed_count = node_state.completed_count,
            .active_child_count = node_state.active_child_count,
            .status = node_state.status,
            .cache_hits = node_state.cache_hits,
            .cache_misses = node_state.cache_misses,
            .last_cache_event = node_state.last_cache_event,
        };
    }

    pub fn begin(
        self: *Manager,
        parent_id: NodeId,
        label: []const u8,
        options: NodeOptions,
    ) ProgressError!NodeId {
        const parent_state = try self.nodeState(parent_id);

        const slot_index = self.nextFreeSlot() orelse return error.ProgressNodeCapacityExceeded;
        const generation = self.allocateGeneration();
        const node_id: NodeId = .{
            .index = @intCast(slot_index),
            .generation = generation,
        };

        self.nodes[slot_index] = NodeState.init(parent_id, generation, label, options.estimated_total);
        parent_state.active_child_count += 1;
        self.active_node = node_id;
        return node_id;
    }

    pub fn updateLabel(self: *Manager, node_id: NodeId, label: []const u8) ProgressError!void {
        const node_state = try self.nodeState(node_id);
        node_state.label = label;
        self.active_node = node_id;
    }

    pub fn updateCurrentItem(self: *Manager, node_id: NodeId, current_item: []const u8) ProgressError!void {
        const node_state = try self.nodeState(node_id);
        node_state.current_item = current_item;
        node_state.last_cache_event = null;
        self.active_node = node_id;
    }

    pub fn setCompletedCount(self: *Manager, node_id: NodeId, completed_count: usize) ProgressError!void {
        const node_state = try self.nodeState(node_id);
        node_state.completed_count = completed_count;
        self.active_node = node_id;
    }

    pub fn completeOne(self: *Manager, node_id: NodeId) ProgressError!void {
        const node_state = try self.nodeState(node_id);
        node_state.completed_count += 1;
        self.active_node = node_id;
    }

    pub fn finish(self: *Manager, node_id: NodeId, result: NodeResult) ProgressError!void {
        const node_state = try self.nodeState(node_id);
        if (node_state.active_child_count > 0) return error.ActiveProgressChildren;

        const status = statusFromResult(result);
        if (node_id.index == 0) {
            node_state.status = status;
            self.active_node = node_id;
            return;
        }

        const parent_id = node_state.parent;
        node_state.status = status;
        node_state.in_use = false;

        if (parent_id) |id| {
            const parent_state = try self.nodeState(id);
            if (parent_state.active_child_count > 0) parent_state.active_child_count -= 1;
            if (sameNodeId(self.active_node, node_id)) self.active_node = id;
        } else if (sameNodeId(self.active_node, node_id)) {
            self.active_node = self.rootId();
        }
    }

    pub fn recordCacheEvent(
        self: *Manager,
        node_id: NodeId,
        kind: CacheEventKind,
        label: []const u8,
        item: []const u8,
    ) ProgressError!void {
        const node_state = try self.nodeState(node_id);
        switch (kind) {
            .hit => node_state.cache_hits += 1,
            .miss => node_state.cache_misses += 1,
        }
        node_state.last_cache_event = .{
            .kind = kind,
            .label = label,
            .item = item,
        };
        self.active_node = node_id;
    }

    pub fn isActive(self: *const Manager, node_id: NodeId) bool {
        const node_state = self.nodeStateConst(node_id) orelse return false;
        return node_state.in_use and node_state.status == .active;
    }

    fn nodeState(self: *Manager, node_id: NodeId) ProgressError!*NodeState {
        if (node_id.index >= max_progress_nodes) return error.InvalidProgressNode;
        const node_state = &self.nodes[node_id.index];
        if (!node_state.in_use or node_state.generation != node_id.generation) {
            return error.InvalidProgressNode;
        }
        return node_state;
    }

    fn nodeStateConst(self: *const Manager, node_id: NodeId) ?*const NodeState {
        if (node_id.index >= max_progress_nodes) return null;
        const node_state = &self.nodes[node_id.index];
        if (!node_state.in_use or node_state.generation != node_id.generation) return null;
        return node_state;
    }

    fn nextFreeSlot(self: *const Manager) ?usize {
        for (1..self.nodes.len) |node_index| {
            if (!self.nodes[node_index].in_use) return node_index;
        }
        return null;
    }

    fn allocateGeneration(self: *Manager) u32 {
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 2;
        return generation;
    }
};

/// Reporter-bound convenience handle for scoped progress updates.
pub const Node = struct {
    reporter: *Reporter,
    id: NodeId,

    pub fn start(self: Node, label: []const u8, options: NodeOptions) ProgressError!Node {
        return self.reporter.beginNode(self.id, label, options);
    }

    pub fn begin(self: Node, label: []const u8, options: NodeOptions) ProgressError!Node {
        return self.start(label, options);
    }

    pub fn updateLabel(self: Node, label: []const u8) void {
        self.reporter.updateNodeLabel(self.id, label);
    }

    pub fn updateCurrentItem(self: Node, current_item: []const u8) void {
        self.reporter.updateNodeCurrentItem(self.id, current_item);
    }

    pub fn setCompletedCount(self: Node, completed_count: usize) void {
        self.reporter.setNodeCompletedCount(self.id, completed_count);
    }

    pub fn completeOne(self: Node) void {
        self.reporter.completeNodeItem(self.id);
    }

    pub fn finish(self: Node, result: NodeResult) void {
        self.reporter.finishNode(self.id, result);
    }

    pub fn cacheHit(self: Node, label: []const u8, item: []const u8) void {
        self.reporter.recordNodeCacheEvent(self.id, .hit, label, item);
    }

    pub fn cacheMiss(self: Node, label: []const u8, item: []const u8) void {
        self.reporter.recordNodeCacheEvent(self.id, .miss, label, item);
    }

    pub fn handoffExternalOutput(self: Node, handoff: ExternalOutputHandoff) void {
        self.reporter.handoffExternalOutput(handoff);
    }

    pub fn output(self: Node, message: []const u8) void {
        self.reporter.output(message);
    }
};

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
    event_sink: ?EventSink = null,
    started: bool = false,
    line_active: bool = false,
    progress_manager: Manager,

    pub fn init(root_name: []const u8, enabled: bool) Reporter {
        return initWithColumns(root_name, enabled, detectTerminalColumns());
    }

    pub fn initWithColumns(root_name: []const u8, enabled: bool, terminal_columns: usize) Reporter {
        return initWithEventSink(root_name, enabled, terminal_columns, null);
    }

    pub fn initWithEventSink(root_name: []const u8, enabled: bool, terminal_columns: usize, event_sink: ?EventSink) Reporter {
        return .{
            .root_name = root_name,
            .enabled = enabled,
            .terminal_columns = normalizeTerminalColumns(terminal_columns),
            .event_sink = event_sink,
            .progress_manager = Manager.init(root_name),
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
        var message_buffer: [4096]u8 = undefined;
        const message = formatStageMessage(&message_buffer, prefix, format, args);
        if (self.event_sink) |sink| sink.stageFn(sink.context, message);

        if (!self.enabled) return;
        self.begin();

        var line_buffer: [512]u8 = undefined;
        const line = formatVisibleLine(&line_buffer, self.terminal_columns, message);

        std.debug.print("\r\x1b[K{s}", .{line});
        self.line_active = true;
    }

    pub fn clearLine(self: *Reporter) void {
        self.handoffExternalOutput(.clear);
    }

    pub fn event(self: *Reporter, comptime format: []const u8, args: anytype) void {
        var message_buffer: [4096]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, format, args) catch "<progress event too long>\n";
        self.output(message);
    }

    pub fn output(self: *Reporter, message: []const u8) void {
        if (self.event_sink) |sink| sink.outputFn(sink.context, message);

        if (!self.enabled) return;
        self.handoffExternalOutput(.clear);
        std.debug.print("{s}", .{message});
    }

    pub fn commitLine(self: *Reporter) void {
        self.handoffExternalOutput(.commit);
    }

    /// Relinquish the stderr progress line before code outside the Zap
    /// progress renderer writes to the terminal.
    pub fn handoffExternalOutput(self: *Reporter, handoff: ExternalOutputHandoff) void {
        if (!self.line_active) return;
        if (self.enabled) {
            switch (handoff) {
                .clear => std.debug.print("\r\x1b[K", .{}),
                .commit => std.debug.print("\n", .{}),
            }
        }
        self.line_active = false;
    }

    pub fn finish(self: *Reporter) void {
        self.clearLine();
    }

    pub fn manager(self: *Reporter) *Manager {
        return &self.progress_manager;
    }

    pub fn rootNode(self: *Reporter) Node {
        return .{
            .reporter = self,
            .id = self.progress_manager.rootId(),
        };
    }

    pub fn start(self: *Reporter, label: []const u8, options: NodeOptions) ProgressError!Node {
        return self.rootNode().start(label, options);
    }

    fn beginNode(self: *Reporter, parent_id: NodeId, label: []const u8, options: NodeOptions) ProgressError!Node {
        const node_id = try self.progress_manager.begin(parent_id, label, options);
        if (self.event_sink) |sink| sink.beginFn(sink.context, parent_id, node_id, label, options);
        self.renderStructuredProgress();
        return .{
            .reporter = self,
            .id = node_id,
        };
    }

    fn updateNodeLabel(self: *Reporter, node_id: NodeId, label: []const u8) void {
        assertProgressMutation(self.progress_manager.updateLabel(node_id, label));
        if (node_id.index == 0) self.root_name = label;
        if (self.event_sink) |sink| sink.updateLabelFn(sink.context, node_id, label);
        self.renderStructuredProgress();
    }

    fn updateNodeCurrentItem(self: *Reporter, node_id: NodeId, current_item: []const u8) void {
        assertProgressMutation(self.progress_manager.updateCurrentItem(node_id, current_item));
        if (self.event_sink) |sink| sink.updateCurrentItemFn(sink.context, node_id, current_item);
        self.renderStructuredProgress();
    }

    fn setNodeCompletedCount(self: *Reporter, node_id: NodeId, completed_count: usize) void {
        assertProgressMutation(self.progress_manager.setCompletedCount(node_id, completed_count));
        if (self.event_sink) |sink| sink.setCompletedCountFn(sink.context, node_id, completed_count);
        self.renderStructuredProgress();
    }

    fn completeNodeItem(self: *Reporter, node_id: NodeId) void {
        assertProgressMutation(self.progress_manager.completeOne(node_id));
        if (self.event_sink) |sink| sink.completeOneFn(sink.context, node_id);
        self.renderStructuredProgress();
    }

    fn finishNode(self: *Reporter, node_id: NodeId, result: NodeResult) void {
        assertProgressMutation(self.progress_manager.finish(node_id, result));
        if (self.event_sink) |sink| sink.finishFn(sink.context, node_id, result);
        self.renderStructuredProgress();
    }

    fn recordNodeCacheEvent(
        self: *Reporter,
        node_id: NodeId,
        kind: CacheEventKind,
        label: []const u8,
        item: []const u8,
    ) void {
        assertProgressMutation(self.progress_manager.recordCacheEvent(node_id, kind, label, item));
        if (self.event_sink) |sink| sink.cacheEventFn(sink.context, node_id, kind, label, item);
        self.renderStructuredProgress();
    }

    fn renderStructuredProgress(self: *Reporter) void {
        if (!self.enabled) return;
        self.begin();

        if (self.progress_manager.active_node.index == 0) {
            self.clearLine();
            return;
        }

        var message_buffer: [4096]u8 = undefined;
        const message = formatNodeMessage(&message_buffer, &self.progress_manager, self.progress_manager.active_node);

        var line_buffer: [512]u8 = undefined;
        const line = formatVisibleLine(&line_buffer, self.terminal_columns, message);

        std.debug.print("\r\x1b[K{s}", .{line});
        self.line_active = true;
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

fn formatNodeMessage(buffer: []u8, manager: *const Manager, node_id: NodeId) []const u8 {
    var len: usize = 0;
    var chain: [max_render_depth]NodeId = undefined;
    var chain_len: usize = 0;
    var truncated = false;
    var current_id = node_id;

    while (current_id.index != 0) {
        const current_state = manager.nodeStateConst(current_id) orelse {
            appendBounded(buffer, &len, "<invalid progress node>");
            return buffer[0..len];
        };

        if (chain_len == chain.len) {
            truncated = true;
            break;
        }
        chain[chain_len] = current_id;
        chain_len += 1;

        current_id = current_state.parent orelse break;
    }

    if (truncated) appendBounded(buffer, &len, "... > ");

    if (chain_len == 0) {
        if (manager.nodeStateConst(manager.rootId())) |root_state| {
            appendBounded(buffer, &len, root_state.label);
        }
    } else {
        var remaining = chain_len;
        while (remaining > 0) {
            remaining -= 1;
            const ancestor_state = manager.nodeStateConst(chain[remaining]) orelse continue;
            if (len > 0 and !std.mem.endsWith(u8, buffer[0..len], "> ")) {
                appendBounded(buffer, &len, " > ");
            }
            appendBounded(buffer, &len, ancestor_state.label);
        }
    }

    const active_state = manager.nodeStateConst(node_id) orelse return buffer[0..len];
    appendNodeProgress(buffer, &len, active_state);
    appendNodeCurrentItem(buffer, &len, active_state);
    appendNodeCacheEvent(buffer, &len, active_state);
    return buffer[0..len];
}

fn appendNodeProgress(buffer: []u8, len: *usize, node_state: *const NodeState) void {
    if (node_state.estimated_total) |estimated_total| {
        appendFormattedBounded(buffer, len, " [{d}/{d}]", .{
            node_state.completed_count,
            estimated_total,
        });
    } else if (node_state.completed_count > 0) {
        appendFormattedBounded(buffer, len, " [{d}]", .{node_state.completed_count});
    }
}

fn appendNodeCurrentItem(buffer: []u8, len: *usize, node_state: *const NodeState) void {
    if (node_state.current_item.len == 0) return;
    appendBounded(buffer, len, ": ");
    appendBounded(buffer, len, node_state.current_item);
}

fn appendNodeCacheEvent(buffer: []u8, len: *usize, node_state: *const NodeState) void {
    const cache_event = node_state.last_cache_event orelse return;
    appendBounded(buffer, len, " (cache ");
    appendBounded(buffer, len, switch (cache_event.kind) {
        .hit => "hit",
        .miss => "miss",
    });

    if (cache_event.label.len > 0) {
        appendBounded(buffer, len, " ");
        appendBounded(buffer, len, cache_event.label);
    }
    if (cache_event.item.len > 0) {
        appendBounded(buffer, len, ": ");
        appendBounded(buffer, len, cache_event.item);
    }
    appendBounded(buffer, len, ")");
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

fn appendFormattedBounded(buffer: []u8, len: *usize, comptime format: []const u8, args: anytype) void {
    if (len.* >= buffer.len) return;
    const written = std.fmt.bufPrint(buffer[len.*..], format, args) catch {
        appendBounded(buffer, len, "...");
        return;
    };
    len.* += written.len;
}

fn appendBounded(buffer: []u8, len: *usize, text: []const u8) void {
    if (len.* >= buffer.len) return;
    const copied_len = @min(text.len, buffer.len - len.*);
    @memcpy(buffer[len.*..][0..copied_len], text[0..copied_len]);
    len.* += copied_len;
}

fn sameNodeId(a: NodeId, b: NodeId) bool {
    return a.index == b.index and a.generation == b.generation;
}

fn statusFromResult(result: NodeResult) NodeStatus {
    return switch (result) {
        .succeeded => .succeeded,
        .failed => .failed,
        .skipped => .skipped,
        .cancelled => .cancelled,
    };
}

fn assertProgressMutation(result: ProgressError!void) void {
    result catch |err| std.debug.panic("progress node mutation failed: {s}", .{@errorName(err)});
}

const RecordingEventSink = struct {
    output_buffer: [256]u8 = undefined,
    output_len: usize = 0,

    fn sink(self: *RecordingEventSink) EventSink {
        return .{
            .context = self,
            .stageFn = stage,
            .outputFn = output,
            .beginFn = begin,
            .updateLabelFn = updateLabel,
            .updateCurrentItemFn = updateCurrentItem,
            .setCompletedCountFn = setCompletedCount,
            .completeOneFn = completeOne,
            .finishFn = finish,
            .cacheEventFn = cacheEvent,
        };
    }

    fn outputText(self: *const RecordingEventSink) []const u8 {
        return self.output_buffer[0..self.output_len];
    }

    fn fromContext(context: *anyopaque) *RecordingEventSink {
        return @ptrCast(@alignCast(context));
    }

    fn stage(context: *anyopaque, message: []const u8) void {
        _ = context;
        _ = message;
    }

    fn output(context: *anyopaque, message: []const u8) void {
        const recorder = fromContext(context);
        const copied_len = @min(message.len, recorder.output_buffer.len);
        @memcpy(recorder.output_buffer[0..copied_len], message[0..copied_len]);
        recorder.output_len = copied_len;
    }

    fn begin(context: *anyopaque, parent_id: NodeId, node_id: NodeId, label: []const u8, options: NodeOptions) void {
        _ = context;
        _ = parent_id;
        _ = node_id;
        _ = label;
        _ = options;
    }

    fn updateLabel(context: *anyopaque, node_id: NodeId, label: []const u8) void {
        _ = context;
        _ = node_id;
        _ = label;
    }

    fn updateCurrentItem(context: *anyopaque, node_id: NodeId, current_item: []const u8) void {
        _ = context;
        _ = node_id;
        _ = current_item;
    }

    fn setCompletedCount(context: *anyopaque, node_id: NodeId, completed_count: usize) void {
        _ = context;
        _ = node_id;
        _ = completed_count;
    }

    fn completeOne(context: *anyopaque, node_id: NodeId) void {
        _ = context;
        _ = node_id;
    }

    fn finish(context: *anyopaque, node_id: NodeId, result: NodeResult) void {
        _ = context;
        _ = node_id;
        _ = result;
    }

    fn cacheEvent(context: *anyopaque, node_id: NodeId, kind: CacheEventKind, label: []const u8, item: []const u8) void {
        _ = context;
        _ = node_id;
        _ = kind;
        _ = label;
        _ = item;
    }
};

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

test "reporter events stream direct output through sink when local rendering is disabled" {
    var recorder: RecordingEventSink = .{};
    var reporter = Reporter.initWithEventSink("Compiling", false, 80, recorder.sink());

    reporter.event("external {s}\n", .{"output"});

    try std.testing.expectEqualStrings("external output\n", recorder.outputText());
    try std.testing.expect(!reporter.started);
    try std.testing.expect(!reporter.line_active);
}

test "external output handoff releases active line state" {
    var reporter = Reporter.initWithColumns("Compiling", false, 80);

    reporter.line_active = true;
    reporter.handoffExternalOutput(.clear);
    try std.testing.expect(!reporter.line_active);

    reporter.line_active = true;
    reporter.handoffExternalOutput(.commit);
    try std.testing.expect(!reporter.line_active);
}

test "manager tracks scoped child lifecycle" {
    var manager = Manager.init("Compiling");
    const root_id = manager.rootId();

    const frontend_id = try manager.begin(root_id, "Frontend", .{ .estimated_total = 3 });
    try manager.setCompletedCount(frontend_id, 1);
    try manager.completeOne(frontend_id);
    try manager.updateCurrentItem(frontend_id, "parser.zap");
    try manager.recordCacheEvent(frontend_id, .hit, "source", "parser.zap");

    const frontend_snapshot = manager.snapshot(frontend_id).?;
    try std.testing.expectEqual(@as(usize, 2), frontend_snapshot.completed_count);
    try std.testing.expectEqual(@as(usize, 1), frontend_snapshot.cache_hits);
    try std.testing.expectEqualStrings("parser.zap", frontend_snapshot.current_item);
    try std.testing.expect(sameNodeId(manager.activeNodeId(), frontend_id));

    try manager.finish(frontend_id, .succeeded);
    try std.testing.expect(!manager.isActive(frontend_id));
    try std.testing.expect(sameNodeId(manager.activeNodeId(), root_id));
}

test "manager rejects finishing nodes with active children" {
    var manager = Manager.init("Compiling");
    const parent_id = try manager.begin(manager.rootId(), "Frontend", .{});
    const child_id = try manager.begin(parent_id, "HIR", .{});

    try std.testing.expectError(error.ActiveProgressChildren, manager.finish(parent_id, .succeeded));
    try manager.finish(child_id, .succeeded);
    try manager.finish(parent_id, .succeeded);
}

test "formatNodeMessage renders nested progress and cache event" {
    var manager = Manager.init("Compiling");
    const frontend_id = try manager.begin(manager.rootId(), "Frontend", .{});
    const hir_id = try manager.begin(frontend_id, "HIR", .{ .estimated_total = 10 });
    try manager.setCompletedCount(hir_id, 4);
    try manager.updateCurrentItem(hir_id, "FunctionDecl");
    try manager.recordCacheEvent(hir_id, .miss, "module", "main.zap");

    var buffer: [256]u8 = undefined;
    const message = formatNodeMessage(&buffer, &manager, hir_id);

    try std.testing.expectEqualStrings(
        "Frontend > HIR [4/10]: FunctionDecl (cache miss module: main.zap)",
        message,
    );
}

test "structured node rendering remains width bounded" {
    var manager = Manager.init("Compiling");
    const frontend_id = try manager.begin(manager.rootId(), "Frontend", .{ .estimated_total = 2617 });
    try manager.setCompletedCount(frontend_id, 2560);
    try manager.updateCurrentItem(frontend_id, "VeryLongFunctionName");

    var message_buffer: [256]u8 = undefined;
    const message = formatNodeMessage(&message_buffer, &manager, frontend_id);

    var line_buffer: [64]u8 = undefined;
    const line = formatVisibleLine(&line_buffer, 24, message);

    try std.testing.expect(line.len <= 23);
    try std.testing.expect(std.mem.startsWith(u8, line, "  "));
    try std.testing.expect(std.mem.endsWith(u8, line, "..."));
}
