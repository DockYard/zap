const std = @import("std");

pub const SCHEMA_VERSION: u16 = 4;

const HASH_DOMAIN = "zap.incremental_graph";

pub const StableDigest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub const PackageKind = enum(u8) {
    project_root = 10,
    stdlib = 20,
    dependency = 30,
};

pub const PackageKey = struct {
    kind: PackageKind,
    name: []const u8,
    root_identity: []const u8,
    version: ?[]const u8 = null,

    pub fn clone(self: PackageKey, allocator: std.mem.Allocator) !PackageKey {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const root_identity = try allocator.dupe(u8, self.root_identity);
        errdefer allocator.free(root_identity);
        const version = if (self.version) |source_version| try allocator.dupe(u8, source_version) else null;
        errdefer if (version) |owned_version| allocator.free(owned_version);

        return .{
            .kind = self.kind,
            .name = name,
            .root_identity = root_identity,
            .version = version,
        };
    }

    pub fn deinit(self: *PackageKey, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.root_identity);
        if (self.version) |version| allocator.free(version);
        self.* = .{
            .kind = .project_root,
            .name = "",
            .root_identity = "",
            .version = null,
        };
    }

    pub fn eql(a: PackageKey, b: PackageKey) bool {
        return a.kind == b.kind and
            std.mem.eql(u8, a.name, b.name) and
            std.mem.eql(u8, a.root_identity, b.root_identity) and
            optionalBytesEql(a.version, b.version);
    }

    pub fn appendStableHash(self: PackageKey, hasher: *StableHasher) void {
        hasher.appendTag(.package_key);
        hasher.appendEnum(self.kind);
        hasher.appendBytes(self.name);
        hasher.appendBytes(self.root_identity);
        hasher.appendOptionalBytes(self.version);
    }

    pub fn stableDigest(self: PackageKey) StableDigest {
        var hasher = StableHasher.init(.package_key);
        self.appendStableHash(&hasher);
        return hasher.final();
    }
};

pub const DeclarationOwnerKind = enum(u8) {
    package = 10,
    @"struct" = 20,
    protocol = 30,
    impl = 40,
    macro_provider = 50,
};

pub const DeclarationOwnerKey = struct {
    package: PackageKey,
    kind: DeclarationOwnerKind,
    qualified_name: []const u8,

    pub fn clone(self: DeclarationOwnerKey, allocator: std.mem.Allocator) !DeclarationOwnerKey {
        var package = try self.package.clone(allocator);
        errdefer package.deinit(allocator);
        const qualified_name = try allocator.dupe(u8, self.qualified_name);
        errdefer allocator.free(qualified_name);

        return .{
            .package = package,
            .kind = self.kind,
            .qualified_name = qualified_name,
        };
    }

    pub fn deinit(self: *DeclarationOwnerKey, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        allocator.free(self.qualified_name);
        self.* = .{
            .package = .{ .kind = .project_root, .name = "", .root_identity = "" },
            .kind = .package,
            .qualified_name = "",
        };
    }

    pub fn eql(a: DeclarationOwnerKey, b: DeclarationOwnerKey) bool {
        return PackageKey.eql(a.package, b.package) and
            a.kind == b.kind and
            std.mem.eql(u8, a.qualified_name, b.qualified_name);
    }

    pub fn appendStableHash(self: DeclarationOwnerKey, hasher: *StableHasher) void {
        hasher.appendTag(.declaration_owner_key);
        self.package.appendStableHash(hasher);
        hasher.appendEnum(self.kind);
        hasher.appendBytes(self.qualified_name);
    }
};

pub const StructKey = struct {
    package: PackageKey,
    qualified_name: []const u8,

    pub fn clone(self: StructKey, allocator: std.mem.Allocator) !StructKey {
        var package = try self.package.clone(allocator);
        errdefer package.deinit(allocator);
        const qualified_name = try allocator.dupe(u8, self.qualified_name);
        errdefer allocator.free(qualified_name);

        return .{
            .package = package,
            .qualified_name = qualified_name,
        };
    }

    pub fn deinit(self: *StructKey, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        allocator.free(self.qualified_name);
        self.* = .{ .package = .{ .kind = .project_root, .name = "", .root_identity = "" }, .qualified_name = "" };
    }

    pub fn eql(a: StructKey, b: StructKey) bool {
        return PackageKey.eql(a.package, b.package) and std.mem.eql(u8, a.qualified_name, b.qualified_name);
    }

    pub fn appendStableHash(self: StructKey, hasher: *StableHasher) void {
        hasher.appendTag(.struct_key);
        self.package.appendStableHash(hasher);
        hasher.appendBytes(self.qualified_name);
    }
};

pub const TypeDefKey = struct {
    package: PackageKey,
    qualified_name: []const u8,

    pub fn clone(self: TypeDefKey, allocator: std.mem.Allocator) !TypeDefKey {
        var package = try self.package.clone(allocator);
        errdefer package.deinit(allocator);
        const qualified_name = try allocator.dupe(u8, self.qualified_name);
        errdefer allocator.free(qualified_name);

        return .{
            .package = package,
            .qualified_name = qualified_name,
        };
    }

    pub fn deinit(self: *TypeDefKey, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        allocator.free(self.qualified_name);
        self.* = .{ .package = .{ .kind = .project_root, .name = "", .root_identity = "" }, .qualified_name = "" };
    }

    pub fn eql(a: TypeDefKey, b: TypeDefKey) bool {
        return PackageKey.eql(a.package, b.package) and std.mem.eql(u8, a.qualified_name, b.qualified_name);
    }

    pub fn appendStableHash(self: TypeDefKey, hasher: *StableHasher) void {
        hasher.appendTag(.type_def_key);
        self.package.appendStableHash(hasher);
        hasher.appendBytes(self.qualified_name);
    }
};

pub const ProtocolKey = struct {
    package: PackageKey,
    qualified_name: []const u8,

    pub fn clone(self: ProtocolKey, allocator: std.mem.Allocator) !ProtocolKey {
        var package = try self.package.clone(allocator);
        errdefer package.deinit(allocator);
        const qualified_name = try allocator.dupe(u8, self.qualified_name);
        errdefer allocator.free(qualified_name);

        return .{
            .package = package,
            .qualified_name = qualified_name,
        };
    }

    pub fn deinit(self: *ProtocolKey, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        allocator.free(self.qualified_name);
        self.* = .{ .package = .{ .kind = .project_root, .name = "", .root_identity = "" }, .qualified_name = "" };
    }

    pub fn eql(a: ProtocolKey, b: ProtocolKey) bool {
        return PackageKey.eql(a.package, b.package) and std.mem.eql(u8, a.qualified_name, b.qualified_name);
    }

    pub fn appendStableHash(self: ProtocolKey, hasher: *StableHasher) void {
        hasher.appendTag(.protocol_key);
        self.package.appendStableHash(hasher);
        hasher.appendBytes(self.qualified_name);
    }
};

pub const ImplKey = struct {
    package: PackageKey,
    module_path: []const u8,
    protocol_qualified_name: []const u8,
    target_type_identity: []const u8,

    pub fn clone(self: ImplKey, allocator: std.mem.Allocator) !ImplKey {
        var package = try self.package.clone(allocator);
        errdefer package.deinit(allocator);
        const module_path = try allocator.dupe(u8, self.module_path);
        errdefer allocator.free(module_path);
        const protocol_qualified_name = try allocator.dupe(u8, self.protocol_qualified_name);
        errdefer allocator.free(protocol_qualified_name);
        const target_type_identity = try allocator.dupe(u8, self.target_type_identity);
        errdefer allocator.free(target_type_identity);

        return .{
            .package = package,
            .module_path = module_path,
            .protocol_qualified_name = protocol_qualified_name,
            .target_type_identity = target_type_identity,
        };
    }

    pub fn deinit(self: *ImplKey, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        allocator.free(self.module_path);
        allocator.free(self.protocol_qualified_name);
        allocator.free(self.target_type_identity);
        self.* = .{
            .package = .{ .kind = .project_root, .name = "", .root_identity = "" },
            .module_path = "",
            .protocol_qualified_name = "",
            .target_type_identity = "",
        };
    }

    pub fn eql(a: ImplKey, b: ImplKey) bool {
        return PackageKey.eql(a.package, b.package) and
            std.mem.eql(u8, a.module_path, b.module_path) and
            std.mem.eql(u8, a.protocol_qualified_name, b.protocol_qualified_name) and
            std.mem.eql(u8, a.target_type_identity, b.target_type_identity);
    }

    pub fn appendStableHash(self: ImplKey, hasher: *StableHasher) void {
        hasher.appendTag(.impl_key);
        self.package.appendStableHash(hasher);
        hasher.appendBytes(self.module_path);
        hasher.appendBytes(self.protocol_qualified_name);
        hasher.appendBytes(self.target_type_identity);
    }
};

pub const MacroKey = struct {
    owner: DeclarationOwnerKey,
    local_name: []const u8,
    arity: u16,

    pub fn clone(self: MacroKey, allocator: std.mem.Allocator) !MacroKey {
        var owner = try self.owner.clone(allocator);
        errdefer owner.deinit(allocator);
        const local_name = try allocator.dupe(u8, self.local_name);
        errdefer allocator.free(local_name);

        return .{
            .owner = owner,
            .local_name = local_name,
            .arity = self.arity,
        };
    }

    pub fn deinit(self: *MacroKey, allocator: std.mem.Allocator) void {
        self.owner.deinit(allocator);
        allocator.free(self.local_name);
        self.* = .{
            .owner = .{ .package = .{ .kind = .project_root, .name = "", .root_identity = "" }, .kind = .package, .qualified_name = "" },
            .local_name = "",
            .arity = 0,
        };
    }

    pub fn eql(a: MacroKey, b: MacroKey) bool {
        return DeclarationOwnerKey.eql(a.owner, b.owner) and
            std.mem.eql(u8, a.local_name, b.local_name) and
            a.arity == b.arity;
    }

    pub fn appendStableHash(self: MacroKey, hasher: *StableHasher) void {
        hasher.appendTag(.macro_key);
        self.owner.appendStableHash(hasher);
        hasher.appendBytes(self.local_name);
        hasher.appendInt(u16, self.arity);
    }
};

pub const FunctionDeclarationKind = enum(u8) {
    free = 10,
    struct_method = 20,
    protocol_slot = 30,
    impl_method = 40,
    macro_expansion = 50,
};

pub const SpecializationValue = union(enum) {
    type_identity: []const u8,
    comptime_string: []const u8,
    comptime_bool: bool,
    comptime_int: i128,
    opaque_digest: StableDigest,

    pub fn clone(self: SpecializationValue, allocator: std.mem.Allocator) !SpecializationValue {
        return switch (self) {
            .type_identity => |value| .{ .type_identity = try allocator.dupe(u8, value) },
            .comptime_string => |value| .{ .comptime_string = try allocator.dupe(u8, value) },
            .comptime_bool => |value| .{ .comptime_bool = value },
            .comptime_int => |value| .{ .comptime_int = value },
            .opaque_digest => |value| .{ .opaque_digest = value },
        };
    }

    pub fn deinit(self: *SpecializationValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .type_identity => |value| allocator.free(value),
            .comptime_string => |value| allocator.free(value),
            .comptime_bool, .comptime_int, .opaque_digest => {},
        }
        self.* = .{ .comptime_bool = false };
    }

    pub fn eql(a: SpecializationValue, b: SpecializationValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .type_identity => |value| std.mem.eql(u8, value, b.type_identity),
            .comptime_string => |value| std.mem.eql(u8, value, b.comptime_string),
            .comptime_bool => |value| value == b.comptime_bool,
            .comptime_int => |value| value == b.comptime_int,
            .opaque_digest => |value| std.mem.eql(u8, &value, &b.opaque_digest),
        };
    }

    pub fn appendStableHash(self: SpecializationValue, hasher: *StableHasher) void {
        hasher.appendTag(.specialization_value);
        switch (self) {
            .type_identity => |value| {
                hasher.appendTag(.specialization_type_identity);
                hasher.appendBytes(value);
            },
            .comptime_string => |value| {
                hasher.appendTag(.specialization_comptime_string);
                hasher.appendBytes(value);
            },
            .comptime_bool => |value| {
                hasher.appendTag(.specialization_comptime_bool);
                hasher.appendBool(value);
            },
            .comptime_int => |value| {
                hasher.appendTag(.specialization_comptime_int);
                hasher.appendI128(value);
            },
            .opaque_digest => |value| {
                hasher.appendTag(.specialization_opaque_digest);
                hasher.appendDigest(value);
            },
        }
    }
};

pub const SpecializationBinding = struct {
    parameter_name: []const u8,
    value: SpecializationValue,

    pub fn clone(self: SpecializationBinding, allocator: std.mem.Allocator) !SpecializationBinding {
        const parameter_name = try allocator.dupe(u8, self.parameter_name);
        errdefer allocator.free(parameter_name);
        var value = try self.value.clone(allocator);
        errdefer value.deinit(allocator);

        return .{
            .parameter_name = parameter_name,
            .value = value,
        };
    }

    pub fn deinit(self: *SpecializationBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.parameter_name);
        self.value.deinit(allocator);
        self.* = .{ .parameter_name = "", .value = .{ .comptime_bool = false } };
    }

    pub fn eql(a: SpecializationBinding, b: SpecializationBinding) bool {
        return std.mem.eql(u8, a.parameter_name, b.parameter_name) and SpecializationValue.eql(a.value, b.value);
    }

    pub fn appendStableHash(self: SpecializationBinding, hasher: *StableHasher) void {
        hasher.appendTag(.specialization_binding);
        hasher.appendBytes(self.parameter_name);
        self.value.appendStableHash(hasher);
    }
};

pub const SpecializationSet = struct {
    bindings: []const SpecializationBinding = &.{},

    pub fn clone(self: SpecializationSet, allocator: std.mem.Allocator) !SpecializationSet {
        const bindings = try allocator.alloc(SpecializationBinding, self.bindings.len);
        var cloned_count: usize = 0;
        errdefer {
            for (bindings[0..cloned_count]) |*binding| binding.deinit(allocator);
            allocator.free(bindings);
        }
        for (self.bindings, 0..) |binding, index| {
            bindings[index] = try binding.clone(allocator);
            cloned_count += 1;
        }
        return .{ .bindings = bindings };
    }

    pub fn deinit(self: *SpecializationSet, allocator: std.mem.Allocator) void {
        for (self.bindings) |binding| {
            var owned_binding = binding;
            owned_binding.deinit(allocator);
        }
        allocator.free(self.bindings);
        self.* = .{ .bindings = &.{} };
    }

    pub fn eql(a: SpecializationSet, b: SpecializationSet) bool {
        if (a.bindings.len != b.bindings.len) return false;
        for (a.bindings, b.bindings) |a_binding, b_binding| {
            if (!SpecializationBinding.eql(a_binding, b_binding)) return false;
        }
        return true;
    }

    pub fn appendStableHash(self: SpecializationSet, hasher: *StableHasher) void {
        hasher.appendTag(.specialization_set);
        hasher.appendInt(u64, self.bindings.len);
        for (self.bindings) |binding| binding.appendStableHash(hasher);
    }
};

pub const FunctionKey = struct {
    owner: DeclarationOwnerKey,
    declaration_kind: FunctionDeclarationKind,
    local_name: []const u8,
    arity: u16,
    clause_index: u32,
    specialization: ?SpecializationSet = null,

    pub fn clone(self: FunctionKey, allocator: std.mem.Allocator) !FunctionKey {
        var owner = try self.owner.clone(allocator);
        errdefer owner.deinit(allocator);
        const local_name = try allocator.dupe(u8, self.local_name);
        errdefer allocator.free(local_name);
        var specialization = if (self.specialization) |source_specialization| try source_specialization.clone(allocator) else null;
        errdefer if (specialization) |*owned_specialization| owned_specialization.deinit(allocator);

        return .{
            .owner = owner,
            .declaration_kind = self.declaration_kind,
            .local_name = local_name,
            .arity = self.arity,
            .clause_index = self.clause_index,
            .specialization = specialization,
        };
    }

    pub fn deinit(self: *FunctionKey, allocator: std.mem.Allocator) void {
        self.owner.deinit(allocator);
        allocator.free(self.local_name);
        if (self.specialization) |*specialization| specialization.deinit(allocator);
        self.* = .{
            .owner = .{ .package = .{ .kind = .project_root, .name = "", .root_identity = "" }, .kind = .package, .qualified_name = "" },
            .declaration_kind = .free,
            .local_name = "",
            .arity = 0,
            .clause_index = 0,
            .specialization = null,
        };
    }

    pub fn eql(a: FunctionKey, b: FunctionKey) bool {
        return DeclarationOwnerKey.eql(a.owner, b.owner) and
            a.declaration_kind == b.declaration_kind and
            std.mem.eql(u8, a.local_name, b.local_name) and
            a.arity == b.arity and
            a.clause_index == b.clause_index and
            optionalSpecializationEql(a.specialization, b.specialization);
    }

    pub fn appendStableHash(self: FunctionKey, hasher: *StableHasher) void {
        hasher.appendTag(.function_key);
        self.owner.appendStableHash(hasher);
        hasher.appendEnum(self.declaration_kind);
        hasher.appendBytes(self.local_name);
        hasher.appendInt(u16, self.arity);
        hasher.appendInt(u32, self.clause_index);
        if (self.specialization) |specialization| {
            hasher.appendBool(true);
            specialization.appendStableHash(hasher);
        } else {
            hasher.appendBool(false);
        }
    }

    pub fn stableDigest(self: FunctionKey) StableDigest {
        var hasher = StableHasher.init(.function_key);
        self.appendStableHash(&hasher);
        return hasher.final();
    }
};

pub const SourceFileKey = struct {
    package: PackageKey,
    path: []const u8,

    pub fn clone(self: SourceFileKey, allocator: std.mem.Allocator) !SourceFileKey {
        var package = try self.package.clone(allocator);
        errdefer package.deinit(allocator);
        const path = try allocator.dupe(u8, self.path);
        errdefer allocator.free(path);

        return .{
            .package = package,
            .path = path,
        };
    }

    pub fn deinit(self: *SourceFileKey, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        allocator.free(self.path);
        self.* = .{ .package = .{ .kind = .project_root, .name = "", .root_identity = "" }, .path = "" };
    }

    pub fn eql(a: SourceFileKey, b: SourceFileKey) bool {
        return PackageKey.eql(a.package, b.package) and std.mem.eql(u8, a.path, b.path);
    }

    pub fn appendStableHash(self: SourceFileKey, hasher: *StableHasher) void {
        hasher.appendTag(.source_file_key);
        self.package.appendStableHash(hasher);
        hasher.appendBytes(self.path);
    }
};

pub const CtfeFileKey = SourceFileKey;

pub const CtfeEnvKey = struct {
    package: PackageKey,
    name: []const u8,

    pub fn clone(self: CtfeEnvKey, allocator: std.mem.Allocator) !CtfeEnvKey {
        var package = try self.package.clone(allocator);
        errdefer package.deinit(allocator);
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);

        return .{
            .package = package,
            .name = name,
        };
    }

    pub fn deinit(self: *CtfeEnvKey, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        allocator.free(self.name);
        self.* = .{ .package = .{ .kind = .project_root, .name = "", .root_identity = "" }, .name = "" };
    }

    pub fn eql(a: CtfeEnvKey, b: CtfeEnvKey) bool {
        return PackageKey.eql(a.package, b.package) and std.mem.eql(u8, a.name, b.name);
    }

    pub fn appendStableHash(self: CtfeEnvKey, hasher: *StableHasher) void {
        hasher.appendTag(.ctfe_env_key);
        self.package.appendStableHash(hasher);
        hasher.appendBytes(self.name);
    }
};

pub const CtfeGlobKey = struct {
    package: PackageKey,
    pattern: []const u8,
    recursive: bool,

    pub fn clone(self: CtfeGlobKey, allocator: std.mem.Allocator) !CtfeGlobKey {
        var package = try self.package.clone(allocator);
        errdefer package.deinit(allocator);
        const pattern = try allocator.dupe(u8, self.pattern);
        errdefer allocator.free(pattern);

        return .{
            .package = package,
            .pattern = pattern,
            .recursive = self.recursive,
        };
    }

    pub fn deinit(self: *CtfeGlobKey, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        allocator.free(self.pattern);
        self.* = .{ .package = .{ .kind = .project_root, .name = "", .root_identity = "" }, .pattern = "", .recursive = false };
    }

    pub fn eql(a: CtfeGlobKey, b: CtfeGlobKey) bool {
        return PackageKey.eql(a.package, b.package) and
            std.mem.eql(u8, a.pattern, b.pattern) and
            a.recursive == b.recursive;
    }

    pub fn appendStableHash(self: CtfeGlobKey, hasher: *StableHasher) void {
        hasher.appendTag(.ctfe_glob_key);
        self.package.appendStableHash(hasher);
        hasher.appendBytes(self.pattern);
        hasher.appendBool(self.recursive);
    }
};

pub const ReflectionKey = struct {
    package: PackageKey,
    query_identity: []const u8,

    pub fn clone(self: ReflectionKey, allocator: std.mem.Allocator) !ReflectionKey {
        var package = try self.package.clone(allocator);
        errdefer package.deinit(allocator);
        const query_identity = try allocator.dupe(u8, self.query_identity);
        errdefer allocator.free(query_identity);

        return .{
            .package = package,
            .query_identity = query_identity,
        };
    }

    pub fn deinit(self: *ReflectionKey, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        allocator.free(self.query_identity);
        self.* = .{ .package = .{ .kind = .project_root, .name = "", .root_identity = "" }, .query_identity = "" };
    }

    pub fn eql(a: ReflectionKey, b: ReflectionKey) bool {
        return PackageKey.eql(a.package, b.package) and std.mem.eql(u8, a.query_identity, b.query_identity);
    }

    pub fn appendStableHash(self: ReflectionKey, hasher: *StableHasher) void {
        hasher.appendTag(.reflection_key);
        self.package.appendStableHash(hasher);
        hasher.appendBytes(self.query_identity);
    }
};

pub const BackendArtifactKey = struct {
    package: PackageKey,
    target_identity: []const u8,
    artifact_identity: []const u8,

    pub fn clone(self: BackendArtifactKey, allocator: std.mem.Allocator) !BackendArtifactKey {
        var package = try self.package.clone(allocator);
        errdefer package.deinit(allocator);
        const target_identity = try allocator.dupe(u8, self.target_identity);
        errdefer allocator.free(target_identity);
        const artifact_identity = try allocator.dupe(u8, self.artifact_identity);
        errdefer allocator.free(artifact_identity);

        return .{
            .package = package,
            .target_identity = target_identity,
            .artifact_identity = artifact_identity,
        };
    }

    pub fn deinit(self: *BackendArtifactKey, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        allocator.free(self.target_identity);
        allocator.free(self.artifact_identity);
        self.* = .{
            .package = .{ .kind = .project_root, .name = "", .root_identity = "" },
            .target_identity = "",
            .artifact_identity = "",
        };
    }

    pub fn eql(a: BackendArtifactKey, b: BackendArtifactKey) bool {
        return PackageKey.eql(a.package, b.package) and
            std.mem.eql(u8, a.target_identity, b.target_identity) and
            std.mem.eql(u8, a.artifact_identity, b.artifact_identity);
    }

    pub fn appendStableHash(self: BackendArtifactKey, hasher: *StableHasher) void {
        hasher.appendTag(.backend_artifact_key);
        self.package.appendStableHash(hasher);
        hasher.appendBytes(self.target_identity);
        hasher.appendBytes(self.artifact_identity);
    }
};

pub const BackendModuleKey = struct {
    package: PackageKey,
    module_identity: []const u8,

    pub fn clone(self: BackendModuleKey, allocator: std.mem.Allocator) !BackendModuleKey {
        var package = try self.package.clone(allocator);
        errdefer package.deinit(allocator);
        const module_identity = try allocator.dupe(u8, self.module_identity);
        errdefer allocator.free(module_identity);

        return .{
            .package = package,
            .module_identity = module_identity,
        };
    }

    pub fn deinit(self: *BackendModuleKey, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        allocator.free(self.module_identity);
        self.* = .{ .package = .{ .kind = .project_root, .name = "", .root_identity = "" }, .module_identity = "" };
    }

    pub fn eql(a: BackendModuleKey, b: BackendModuleKey) bool {
        return PackageKey.eql(a.package, b.package) and std.mem.eql(u8, a.module_identity, b.module_identity);
    }

    pub fn appendStableHash(self: BackendModuleKey, hasher: *StableHasher) void {
        hasher.appendTag(.backend_module_key);
        self.package.appendStableHash(hasher);
        hasher.appendBytes(self.module_identity);
    }
};

pub const NodeKind = enum(u8) {
    source_file = 10,
    package_surface = 20,
    struct_surface = 30,
    macro_provider = 40,
    function_signature = 50,
    function_body = 60,
    type_layout = 70,
    protocol = 80,
    impl = 90,
    ctfe_file = 100,
    ctfe_env = 110,
    ctfe_glob = 120,
    ctfe_reflection = 130,
    backend_artifact = 140,
    backend_module = 150,
};

pub const NodeKey = union(NodeKind) {
    source_file: SourceFileKey,
    package_surface: PackageKey,
    struct_surface: StructKey,
    macro_provider: MacroKey,
    function_signature: FunctionKey,
    function_body: FunctionKey,
    type_layout: TypeDefKey,
    protocol: ProtocolKey,
    impl: ImplKey,
    ctfe_file: CtfeFileKey,
    ctfe_env: CtfeEnvKey,
    ctfe_glob: CtfeGlobKey,
    ctfe_reflection: ReflectionKey,
    backend_artifact: BackendArtifactKey,
    backend_module: BackendModuleKey,

    pub const Context = struct {
        pub fn hash(_: Context, key: NodeKey) u64 {
            return key.stableHash64();
        }

        pub fn eql(_: Context, a: NodeKey, b: NodeKey) bool {
            return NodeKey.eql(a, b);
        }
    };

    pub fn kind(self: NodeKey) NodeKind {
        return std.meta.activeTag(self);
    }

    pub fn clone(self: NodeKey, allocator: std.mem.Allocator) !NodeKey {
        return switch (self) {
            .source_file => |key| .{ .source_file = try key.clone(allocator) },
            .package_surface => |key| .{ .package_surface = try key.clone(allocator) },
            .struct_surface => |key| .{ .struct_surface = try key.clone(allocator) },
            .macro_provider => |key| .{ .macro_provider = try key.clone(allocator) },
            .function_signature => |key| .{ .function_signature = try key.clone(allocator) },
            .function_body => |key| .{ .function_body = try key.clone(allocator) },
            .type_layout => |key| .{ .type_layout = try key.clone(allocator) },
            .protocol => |key| .{ .protocol = try key.clone(allocator) },
            .impl => |key| .{ .impl = try key.clone(allocator) },
            .ctfe_file => |key| .{ .ctfe_file = try key.clone(allocator) },
            .ctfe_env => |key| .{ .ctfe_env = try key.clone(allocator) },
            .ctfe_glob => |key| .{ .ctfe_glob = try key.clone(allocator) },
            .ctfe_reflection => |key| .{ .ctfe_reflection = try key.clone(allocator) },
            .backend_artifact => |key| .{ .backend_artifact = try key.clone(allocator) },
            .backend_module => |key| .{ .backend_module = try key.clone(allocator) },
        };
    }

    pub fn deinit(self: *NodeKey, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .source_file => |*key| key.deinit(allocator),
            .package_surface => |*key| key.deinit(allocator),
            .struct_surface => |*key| key.deinit(allocator),
            .macro_provider => |*key| key.deinit(allocator),
            .function_signature => |*key| key.deinit(allocator),
            .function_body => |*key| key.deinit(allocator),
            .type_layout => |*key| key.deinit(allocator),
            .protocol => |*key| key.deinit(allocator),
            .impl => |*key| key.deinit(allocator),
            .ctfe_file => |*key| key.deinit(allocator),
            .ctfe_env => |*key| key.deinit(allocator),
            .ctfe_glob => |*key| key.deinit(allocator),
            .ctfe_reflection => |*key| key.deinit(allocator),
            .backend_artifact => |*key| key.deinit(allocator),
            .backend_module => |*key| key.deinit(allocator),
        }
    }

    pub fn eql(a: NodeKey, b: NodeKey) bool {
        if (a.kind() != b.kind()) return false;
        return switch (a) {
            .source_file => |key| SourceFileKey.eql(key, b.source_file),
            .package_surface => |key| PackageKey.eql(key, b.package_surface),
            .struct_surface => |key| StructKey.eql(key, b.struct_surface),
            .macro_provider => |key| MacroKey.eql(key, b.macro_provider),
            .function_signature => |key| FunctionKey.eql(key, b.function_signature),
            .function_body => |key| FunctionKey.eql(key, b.function_body),
            .type_layout => |key| TypeDefKey.eql(key, b.type_layout),
            .protocol => |key| ProtocolKey.eql(key, b.protocol),
            .impl => |key| ImplKey.eql(key, b.impl),
            .ctfe_file => |key| CtfeFileKey.eql(key, b.ctfe_file),
            .ctfe_env => |key| CtfeEnvKey.eql(key, b.ctfe_env),
            .ctfe_glob => |key| CtfeGlobKey.eql(key, b.ctfe_glob),
            .ctfe_reflection => |key| ReflectionKey.eql(key, b.ctfe_reflection),
            .backend_artifact => |key| BackendArtifactKey.eql(key, b.backend_artifact),
            .backend_module => |key| BackendModuleKey.eql(key, b.backend_module),
        };
    }

    pub fn appendStableHash(self: NodeKey, hasher: *StableHasher) void {
        hasher.appendTag(.node_key);
        hasher.appendEnum(self.kind());
        switch (self) {
            .source_file => |key| key.appendStableHash(hasher),
            .package_surface => |key| {
                hasher.appendTag(.package_surface_key);
                key.appendStableHash(hasher);
            },
            .struct_surface => |key| key.appendStableHash(hasher),
            .macro_provider => |key| key.appendStableHash(hasher),
            .function_signature => |key| key.appendStableHash(hasher),
            .function_body => |key| key.appendStableHash(hasher),
            .type_layout => |key| key.appendStableHash(hasher),
            .protocol => |key| key.appendStableHash(hasher),
            .impl => |key| key.appendStableHash(hasher),
            .ctfe_file => |key| key.appendStableHash(hasher),
            .ctfe_env => |key| key.appendStableHash(hasher),
            .ctfe_glob => |key| key.appendStableHash(hasher),
            .ctfe_reflection => |key| key.appendStableHash(hasher),
            .backend_artifact => |key| key.appendStableHash(hasher),
            .backend_module => |key| key.appendStableHash(hasher),
        }
    }

    pub fn stableDigest(self: NodeKey) StableDigest {
        var hasher = StableHasher.init(.node_key);
        self.appendStableHash(&hasher);
        return hasher.final();
    }

    pub fn stableHash64(self: NodeKey) u64 {
        const digest = self.stableDigest();
        return std.mem.readInt(u64, digest[0..8], .little);
    }
};

pub const DependencyReason = enum(u8) {
    import = 10,
    surface = 20,
    macro_expansion = 30,
    before_compile = 40,
    ctfe_file = 50,
    ctfe_env = 60,
    ctfe_glob = 70,
    ctfe_reflection = 80,
    protocol_slot = 90,
    impl_table = 100,
    type_layout = 110,
    call_edge = 120,
    specialization = 130,
    analysis_summary = 140,
    backend_emission = 150,
};

pub const NodeId = enum(u32) {
    _,

    pub fn index(self: NodeId) usize {
        return @intFromEnum(self);
    }
};

pub const Edge = struct {
    depender: NodeId,
    dependee: NodeId,
    reason: DependencyReason,

    pub const Context = struct {
        pub fn hash(_: Context, edge: Edge) u64 {
            var hasher = StableHasher.init(.edge_key);
            hasher.appendEnum(edge.reason);
            hasher.appendInt(u32, @intFromEnum(edge.depender));
            hasher.appendInt(u32, @intFromEnum(edge.dependee));
            return hasher.final64();
        }

        pub fn eql(_: Context, a: Edge, b: Edge) bool {
            return a.depender == b.depender and a.dependee == b.dependee and a.reason == b.reason;
        }
    };
};

pub const AffectedStep = struct {
    depender: NodeId,
    dependee: NodeId,
    reason: DependencyReason,
};

pub const DeclarationFingerprintKind = enum(u8) {
    root_glue = 10,
    struct_surface = 20,
    function_signature = 30,
    function_body = 40,
    macro_provider = 50,
    ctfe_glob = 60,
    ctfe_reflection = 70,
};

pub const DeclarationFingerprint = struct {
    key: NodeKey,
    kind: DeclarationFingerprintKind,
    digest: StableDigest,
};

pub const DeclarationFingerprintSet = struct {
    /// File-level declaration glue that is not yet represented by a graph
    /// node. A change here intentionally falls back to the existing
    /// conservative source-file invalidation path.
    root_glue: ?StableDigest = null,
    records: []const DeclarationFingerprint,
};

pub const DeclarationFingerprintFallbackReason = enum {
    missing_previous_state,
    missing_current_state,
    root_glue_changed,
    ambiguous_fingerprint_kind,
    duplicate_previous_node,
    duplicate_current_node,
    missing_changed_node,
};

pub const DeclarationRootSelection = struct {
    roots: []const NodeId,
    fallback_reason: ?DeclarationFingerprintFallbackReason = null,

    pub fn deinit(self: *DeclarationRootSelection, allocator: std.mem.Allocator) void {
        allocator.free(self.roots);
        self.* = .{ .roots = &.{}, .fallback_reason = null };
    }

    pub fn isPrecise(self: DeclarationRootSelection) bool {
        return self.fallback_reason == null;
    }
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(NodeRecord) = .empty,
    node_ids_by_digest: NodeDigestMap = .empty,
    edges: EdgeSet = .empty,
    reverse_edges_by_dependee: ReverseAdjacencyMap = .empty,

    const NodeDigestMap = std.AutoHashMapUnmanaged(StableDigest, NodeId);
    const EdgeSet = std.HashMapUnmanaged(Edge, void, Edge.Context, std.hash_map.default_max_load_percentage);
    const EdgeList = std.ArrayListUnmanaged(Edge);
    const ReverseAdjacencyMap = std.AutoHashMapUnmanaged(NodeId, EdgeList);
    const NodeRecord = struct {
        key: NodeKey,
        digest: StableDigest,

        fn deinit(self: *NodeRecord, allocator: std.mem.Allocator) void {
            self.key.deinit(allocator);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Graph) void {
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        var reverse_iterator = self.reverse_edges_by_dependee.valueIterator();
        while (reverse_iterator.next()) |edges| edges.deinit(self.allocator);
        self.reverse_edges_by_dependee.deinit(self.allocator);
        self.node_ids_by_digest.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.* = Graph.init(self.allocator);
    }

    pub fn getNode(self: *const Graph, key: NodeKey) !?NodeId {
        const digest = key.stableDigest();
        const existing_id = self.node_ids_by_digest.get(digest) orelse return null;
        const existing_key = self.nodeKey(existing_id) orelse return error.UnknownIncrementalGraphNode;
        if (!NodeKey.eql(existing_key.*, key)) return error.IncrementalGraphDigestCollision;
        return existing_id;
    }

    pub fn getOrPutNode(self: *Graph, key: NodeKey) !NodeId {
        const digest = key.stableDigest();
        if (self.node_ids_by_digest.get(digest)) |existing_id| {
            const existing_key = self.nodeKey(existing_id) orelse return error.UnknownIncrementalGraphNode;
            if (!NodeKey.eql(existing_key.*, key)) return error.IncrementalGraphDigestCollision;
            return existing_id;
        }

        try self.nodes.ensureUnusedCapacity(self.allocator, 1);
        try self.node_ids_by_digest.ensureUnusedCapacity(self.allocator, 1);
        const owned_key = try key.clone(self.allocator);
        errdefer {
            var mutable_key = owned_key;
            mutable_key.deinit(self.allocator);
        }

        const id: NodeId = @enumFromInt(self.nodes.items.len);
        self.node_ids_by_digest.putAssumeCapacityNoClobber(digest, id);
        self.nodes.appendAssumeCapacity(.{ .key = owned_key, .digest = digest });
        return id;
    }

    pub fn nodeKind(self: *const Graph, id: NodeId) ?NodeKind {
        const key = self.nodeKey(id) orelse return null;
        return key.kind();
    }

    pub fn nodeKey(self: *const Graph, id: NodeId) ?*const NodeKey {
        if (id.index() >= self.nodes.items.len) return null;
        return &self.nodes.items[id.index()].key;
    }

    pub fn nodeDigest(self: *const Graph, id: NodeId) ?*const StableDigest {
        if (id.index() >= self.nodes.items.len) return null;
        return &self.nodes.items[id.index()].digest;
    }

    pub fn nodeCount(self: *const Graph) usize {
        return self.nodes.items.len;
    }

    pub fn edgeCount(self: *const Graph) usize {
        return self.edges.count();
    }

    pub fn addEdge(self: *Graph, depender: NodeId, dependee: NodeId, reason: DependencyReason) !void {
        try self.requireNode(depender);
        try self.requireNode(dependee);
        const edge: Edge = .{ .depender = depender, .dependee = dependee, .reason = reason };
        if (self.edges.contains(edge)) return;

        try self.edges.ensureUnusedCapacity(self.allocator, 1);
        const reverse_entry = try self.reverse_edges_by_dependee.getOrPut(self.allocator, dependee);
        if (!reverse_entry.found_existing) {
            reverse_entry.value_ptr.* = .empty;
        }
        errdefer if (!reverse_entry.found_existing) {
            _ = self.reverse_edges_by_dependee.remove(dependee);
        };
        try reverse_entry.value_ptr.ensureUnusedCapacity(self.allocator, 1);

        self.edges.putAssumeCapacityNoClobber(edge, {});
        reverse_entry.value_ptr.appendAssumeCapacity(edge);
    }

    pub fn affectedFrom(self: *const Graph, allocator: std.mem.Allocator, changed_dependees: []const NodeId) ![]NodeId {
        const steps = try self.affectedTraceFrom(allocator, changed_dependees);
        defer allocator.free(steps);

        var result: std.ArrayList(NodeId) = .empty;
        errdefer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, steps.len);
        for (steps) |step| result.appendAssumeCapacity(step.depender);
        return result.toOwnedSlice(allocator);
    }

    pub fn affectedTraceFrom(self: *const Graph, allocator: std.mem.Allocator, changed_dependees: []const NodeId) ![]AffectedStep {
        var visited = std.AutoHashMapUnmanaged(NodeId, void).empty;
        defer visited.deinit(allocator);

        var worklist: std.ArrayList(NodeId) = .empty;
        defer worklist.deinit(allocator);

        var steps: std.ArrayList(AffectedStep) = .empty;
        errdefer steps.deinit(allocator);

        for (changed_dependees) |dependee| {
            try self.requireNode(dependee);
            const visited_entry = try visited.getOrPut(allocator, dependee);
            if (!visited_entry.found_existing) {
                try worklist.append(allocator, dependee);
            }
        }

        var cursor: usize = 0;
        while (cursor < worklist.items.len) : (cursor += 1) {
            const current_dependee = worklist.items[cursor];
            const reverse_edges = self.reverse_edges_by_dependee.get(current_dependee) orelse continue;
            for (reverse_edges.items) |edge| {
                const visited_entry = try visited.getOrPut(allocator, edge.depender);
                if (!visited_entry.found_existing) {
                    try worklist.append(allocator, edge.depender);
                    try steps.append(allocator, .{
                        .depender = edge.depender,
                        .dependee = edge.dependee,
                        .reason = edge.reason,
                    });
                }
            }
        }

        std.mem.sort(AffectedStep, steps.items, {}, compareAffectedSteps);
        return steps.toOwnedSlice(allocator);
    }

    fn requireNode(self: *const Graph, id: NodeId) !void {
        if (id.index() >= self.nodes.items.len) return error.UnknownIncrementalGraphNode;
    }
};

pub fn selectChangedDeclarationRoots(
    allocator: std.mem.Allocator,
    graph: *const Graph,
    previous: ?DeclarationFingerprintSet,
    current: ?DeclarationFingerprintSet,
) !DeclarationRootSelection {
    const previous_set = previous orelse return fallbackDeclarationRootSelection(.missing_previous_state);
    const current_set = current orelse return fallbackDeclarationRootSelection(.missing_current_state);

    if (!optionalDigestEql(previous_set.root_glue, current_set.root_glue)) {
        return fallbackDeclarationRootSelection(.root_glue_changed);
    }

    var previous_index = DeclarationFingerprintIndex.empty;
    defer previous_index.deinit(allocator);
    if (try indexDeclarationFingerprints(allocator, previous_set.records, &previous_index, .duplicate_previous_node)) |reason| {
        return fallbackDeclarationRootSelection(reason);
    }

    var current_index = DeclarationFingerprintIndex.empty;
    defer current_index.deinit(allocator);
    if (try indexDeclarationFingerprints(allocator, current_set.records, &current_index, .duplicate_current_node)) |reason| {
        return fallbackDeclarationRootSelection(reason);
    }

    var root_set = std.AutoHashMapUnmanaged(NodeId, void).empty;
    defer root_set.deinit(allocator);

    var roots: std.ArrayList(NodeId) = .empty;
    var roots_transferred = false;
    defer if (!roots_transferred) roots.deinit(allocator);

    for (current_set.records) |current_record| {
        if (!declarationFingerprintKindMatchesKey(current_record.kind, current_record.key)) {
            return fallbackDeclarationRootSelection(.ambiguous_fingerprint_kind);
        }
        const previous_index_value = previous_index.get(current_record.key) orelse {
            const root_id = (try graph.getNode(current_record.key)) orelse
                return fallbackDeclarationRootSelection(.missing_changed_node);
            try appendUniqueRoot(allocator, &root_set, &roots, root_id);
            continue;
        };
        const previous_record = previous_set.records[previous_index_value];
        if (!std.mem.eql(u8, previous_record.digest[0..], current_record.digest[0..])) {
            const root_id = (try graph.getNode(current_record.key)) orelse
                return fallbackDeclarationRootSelection(.missing_changed_node);
            try appendUniqueRoot(allocator, &root_set, &roots, root_id);
        }
    }

    for (previous_set.records) |previous_record| {
        if (!declarationFingerprintKindMatchesKey(previous_record.kind, previous_record.key)) {
            return fallbackDeclarationRootSelection(.ambiguous_fingerprint_kind);
        }
        if (current_index.contains(previous_record.key)) continue;
        return fallbackDeclarationRootSelection(.missing_changed_node);
    }

    std.mem.sort(NodeId, roots.items, {}, compareNodeIds);
    const owned_roots = try roots.toOwnedSlice(allocator);
    roots_transferred = true;
    return .{
        .roots = owned_roots,
        .fallback_reason = null,
    };
}

const DeclarationFingerprintIndex = std.HashMapUnmanaged(
    NodeKey,
    usize,
    NodeKey.Context,
    std.hash_map.default_max_load_percentage,
);

fn indexDeclarationFingerprints(
    allocator: std.mem.Allocator,
    records: []const DeclarationFingerprint,
    index: *DeclarationFingerprintIndex,
    duplicate_reason: DeclarationFingerprintFallbackReason,
) !?DeclarationFingerprintFallbackReason {
    for (records, 0..) |record, record_index| {
        if (!declarationFingerprintKindMatchesKey(record.kind, record.key)) {
            return .ambiguous_fingerprint_kind;
        }
        const entry = try index.getOrPut(allocator, record.key);
        if (entry.found_existing) {
            return duplicate_reason;
        }
        entry.value_ptr.* = record_index;
    }
    return null;
}

fn optionalDigestEql(a: ?StableDigest, b: ?StableDigest) bool {
    if (a == null or b == null) return a == null and b == null;
    const left = a.?;
    const right = b.?;
    return std.mem.eql(u8, left[0..], right[0..]);
}

fn declarationFingerprintKindMatchesKey(kind: DeclarationFingerprintKind, key: NodeKey) bool {
    return switch (kind) {
        .root_glue => false,
        .struct_surface => key.kind() == .struct_surface,
        .function_signature => key.kind() == .function_signature,
        .function_body => key.kind() == .function_body,
        .macro_provider => key.kind() == .macro_provider,
        .ctfe_glob => key.kind() == .ctfe_glob,
        .ctfe_reflection => key.kind() == .ctfe_reflection,
    };
}

fn appendUniqueRoot(
    allocator: std.mem.Allocator,
    root_set: *std.AutoHashMapUnmanaged(NodeId, void),
    roots: *std.ArrayList(NodeId),
    root_id: NodeId,
) !void {
    const entry = try root_set.getOrPut(allocator, root_id);
    if (entry.found_existing) return;
    try roots.append(allocator, root_id);
}

fn fallbackDeclarationRootSelection(reason: DeclarationFingerprintFallbackReason) DeclarationRootSelection {
    return .{ .roots = &.{}, .fallback_reason = reason };
}

pub const StableHashTag = enum(u16) {
    domain = 0,
    package_key = 10,
    package_surface_key = 20,
    declaration_owner_key = 30,
    struct_key = 40,
    type_def_key = 50,
    protocol_key = 60,
    impl_key = 70,
    macro_key = 80,
    function_key = 90,
    source_file_key = 100,
    ctfe_env_key = 110,
    ctfe_glob_key = 120,
    reflection_key = 130,
    backend_artifact_key = 140,
    backend_module_key = 150,
    node_key = 160,
    edge_key = 170,
    specialization_set = 180,
    specialization_binding = 190,
    specialization_value = 200,
    specialization_type_identity = 210,
    specialization_comptime_string = 220,
    specialization_comptime_bool = 230,
    specialization_comptime_int = 240,
    specialization_opaque_digest = 250,
    declaration_fingerprint = 260,
    struct_surface_fingerprint = 270,
    function_signature_fingerprint = 280,
    function_body_fingerprint = 290,
    macro_provider_fingerprint = 300,
    root_glue_fingerprint = 310,
    ctfe_glob_fingerprint = 320,
    ctfe_reflection_fingerprint = 330,
};

pub const StableHasher = struct {
    inner: std.crypto.hash.sha2.Sha256,

    pub fn init(root_tag: StableHashTag) StableHasher {
        var self = StableHasher{ .inner = std.crypto.hash.sha2.Sha256.init(.{}) };
        self.appendTag(.domain);
        self.appendBytes(HASH_DOMAIN);
        self.appendInt(u16, SCHEMA_VERSION);
        self.appendTag(root_tag);
        return self;
    }

    pub fn appendTag(self: *StableHasher, tag: StableHashTag) void {
        self.appendInt(u16, @intFromEnum(tag));
    }

    pub fn appendEnum(self: *StableHasher, value: anytype) void {
        self.appendInt(u64, @intFromEnum(value));
    }

    pub fn appendBool(self: *StableHasher, value: bool) void {
        self.appendInt(u8, @intFromBool(value));
    }

    pub fn appendBytes(self: *StableHasher, bytes: []const u8) void {
        self.appendInt(u64, bytes.len);
        self.inner.update(bytes);
    }

    pub fn appendOptionalBytes(self: *StableHasher, bytes: ?[]const u8) void {
        if (bytes) |some| {
            self.appendBool(true);
            self.appendBytes(some);
        } else {
            self.appendBool(false);
        }
    }

    pub fn appendDigest(self: *StableHasher, digest: StableDigest) void {
        self.appendInt(u64, digest.len);
        self.inner.update(&digest);
    }

    pub fn appendI128(self: *StableHasher, value: i128) void {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &bytes, @bitCast(value), .little);
        self.inner.update(&bytes);
    }

    pub fn appendInt(self: *StableHasher, comptime T: type, value: anytype) void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, @intCast(value), .little);
        self.inner.update(&bytes);
    }

    pub fn final(self: *StableHasher) StableDigest {
        var digest: StableDigest = undefined;
        self.inner.final(&digest);
        return digest;
    }

    pub fn final64(self: *StableHasher) u64 {
        const digest = self.final();
        return std.mem.readInt(u64, digest[0..8], .little);
    }
};

fn optionalBytesEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn optionalSpecializationEql(a: ?SpecializationSet, b: ?SpecializationSet) bool {
    if (a == null or b == null) return a == null and b == null;
    return SpecializationSet.eql(a.?, b.?);
}

fn compareNodeIds(_: void, a: NodeId, b: NodeId) bool {
    return @intFromEnum(a) < @intFromEnum(b);
}

fn compareAffectedSteps(_: void, a: AffectedStep, b: AffectedStep) bool {
    if (a.depender != b.depender) return @intFromEnum(a.depender) < @intFromEnum(b.depender);
    if (a.dependee != b.dependee) return @intFromEnum(a.dependee) < @intFromEnum(b.dependee);
    return @intFromEnum(a.reason) < @intFromEnum(b.reason);
}

fn testPackage() PackageKey {
    return .{
        .kind = .project_root,
        .name = "app",
        .root_identity = "root-digest",
        .version = "0.1.0",
    };
}

fn testOwner() DeclarationOwnerKey {
    return .{
        .package = testPackage(),
        .kind = .@"struct",
        .qualified_name = "Example.Counter",
    };
}

fn testFunctionKey() FunctionKey {
    return .{
        .owner = testOwner(),
        .declaration_kind = .struct_method,
        .local_name = "increment",
        .arity = 1,
        .clause_index = 0,
    };
}

fn testFingerprintDigest(bytes: []const u8) StableDigest {
    var hasher = StableHasher.init(.declaration_fingerprint);
    hasher.appendBytes(bytes);
    return hasher.final();
}

fn testDeclarationFingerprint(
    kind: DeclarationFingerprintKind,
    key: NodeKey,
    bytes: []const u8,
) DeclarationFingerprint {
    return .{
        .key = key,
        .kind = kind,
        .digest = testFingerprintDigest(bytes),
    };
}

test "incremental graph keys - equivalent keys hash and equal regardless of allocation order" {
    const allocator = std.testing.allocator;

    const first_name = try allocator.dupe(u8, "app");
    defer allocator.free(first_name);
    const first_root = try allocator.dupe(u8, "root-digest");
    defer allocator.free(first_root);
    const first_qualified = try allocator.dupe(u8, "Example.Counter");
    defer allocator.free(first_qualified);

    const second_qualified = try allocator.dupe(u8, "Example.Counter");
    defer allocator.free(second_qualified);
    const second_root = try allocator.dupe(u8, "root-digest");
    defer allocator.free(second_root);
    const second_name = try allocator.dupe(u8, "app");
    defer allocator.free(second_name);

    const first = NodeKey{ .struct_surface = .{
        .package = .{ .kind = .project_root, .name = first_name, .root_identity = first_root, .version = "0.1.0" },
        .qualified_name = first_qualified,
    } };
    const second = NodeKey{ .struct_surface = .{
        .package = .{ .kind = .project_root, .name = second_name, .root_identity = second_root, .version = "0.1.0" },
        .qualified_name = second_qualified,
    } };

    try std.testing.expect(NodeKey.eql(first, second));
    try std.testing.expectEqual(first.stableDigest(), second.stableDigest());
    try std.testing.expectEqual(first.stableHash64(), second.stableHash64());
}

test "incremental graph nodes - function signature and body are distinct typed nodes" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const function = testFunctionKey();
    const signature_id = try graph.getOrPutNode(.{ .function_signature = function });
    const body_id = try graph.getOrPutNode(.{ .function_body = function });

    try std.testing.expect(signature_id != body_id);
    try std.testing.expectEqual(NodeKind.function_signature, graph.nodeKind(signature_id).?);
    try std.testing.expectEqual(NodeKind.function_body, graph.nodeKind(body_id).?);
    try std.testing.expectEqual(@as(usize, 2), graph.nodeCount());
}

test "incremental graph nodes - package surface is distinct from struct surface" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const package_id = try graph.getOrPutNode(.{ .package_surface = testPackage() });
    const struct_id = try graph.getOrPutNode(.{ .struct_surface = .{
        .package = testPackage(),
        .qualified_name = "",
    } });

    try std.testing.expect(package_id != struct_id);
    try std.testing.expectEqual(NodeKind.package_surface, graph.nodeKind(package_id).?);
    try std.testing.expectEqual(NodeKind.struct_surface, graph.nodeKind(struct_id).?);
}

test "incremental graph stable discriminants are frozen" {
    try std.testing.expectEqual(@as(u8, 20), @intFromEnum(NodeKind.package_surface));
    try std.testing.expectEqual(@as(u8, 30), @intFromEnum(NodeKind.struct_surface));
    try std.testing.expect(@intFromEnum(NodeKind.package_surface) != @intFromEnum(NodeKind.struct_surface));

    try std.testing.expectEqual(@as(u16, 10), @intFromEnum(StableHashTag.package_key));
    try std.testing.expectEqual(@as(u16, 20), @intFromEnum(StableHashTag.package_surface_key));
    try std.testing.expect(@intFromEnum(StableHashTag.package_key) != @intFromEnum(StableHashTag.package_surface_key));

    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(PackageKind.project_root));
    try std.testing.expectEqual(@as(u8, 20), @intFromEnum(DeclarationOwnerKind.@"struct"));
    try std.testing.expectEqual(@as(u8, 20), @intFromEnum(FunctionDeclarationKind.struct_method));
    try std.testing.expectEqual(@as(u8, 120), @intFromEnum(DependencyReason.call_edge));
}

test "incremental graph nodes - borrowed key and digest accessors expose inserted records" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const key = NodeKey{ .source_file = .{ .package = testPackage(), .path = "lib/counter.zap" } };
    const id = try graph.getOrPutNode(key);
    const expected_digest = key.stableDigest();

    const borrowed_key = graph.nodeKey(id).?;
    const borrowed_digest = graph.nodeDigest(id).?;

    try std.testing.expect(NodeKey.eql(key, borrowed_key.*));
    try std.testing.expectEqualSlices(u8, expected_digest[0..], borrowed_digest[0..]);
    try std.testing.expectEqual(id, (try graph.getNode(key)).?);
}

test "incremental graph - duplicate nodes and edges are coalesced" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const function = testFunctionKey();
    const first_body_id = try graph.getOrPutNode(.{ .function_body = function });
    const second_body_id = try graph.getOrPutNode(.{ .function_body = function });
    const source_id = try graph.getOrPutNode(.{ .source_file = .{ .package = testPackage(), .path = "lib/counter.zap" } });

    try graph.addEdge(first_body_id, source_id, .import);
    try graph.addEdge(first_body_id, source_id, .import);

    try std.testing.expectEqual(first_body_id, second_body_id);
    try std.testing.expectEqual(@as(usize, 2), graph.nodeCount());
    try std.testing.expectEqual(@as(usize, 1), graph.edgeCount());
}

test "incremental graph invalidation - duplicate reverse edges do not duplicate traversal results" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const source_id = try graph.getOrPutNode(.{ .source_file = .{ .package = testPackage(), .path = "lib/counter.zap" } });
    const body_id = try graph.getOrPutNode(.{ .function_body = testFunctionKey() });
    const backend_id = try graph.getOrPutNode(.{ .backend_artifact = .{
        .package = testPackage(),
        .target_identity = "native-debug",
        .artifact_identity = "counter-object",
    } });

    try graph.addEdge(body_id, source_id, .import);
    try graph.addEdge(body_id, source_id, .import);
    try graph.addEdge(backend_id, body_id, .backend_emission);
    try graph.addEdge(backend_id, body_id, .backend_emission);

    const affected = try graph.affectedFrom(std.testing.allocator, &.{source_id});
    defer std.testing.allocator.free(affected);

    try std.testing.expectEqual(@as(usize, 2), graph.edgeCount());
    try std.testing.expectEqualSlices(NodeId, &.{ body_id, backend_id }, affected);
}

test "incremental graph invalidation - transitive reverse edges are traversed deterministically" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const source_id = try graph.getOrPutNode(.{ .source_file = .{ .package = testPackage(), .path = "lib/counter.zap" } });
    const body_id = try graph.getOrPutNode(.{ .function_body = testFunctionKey() });
    const backend_id = try graph.getOrPutNode(.{ .backend_module = .{ .package = testPackage(), .module_identity = "app:counter" } });

    try graph.addEdge(backend_id, body_id, .backend_emission);
    try graph.addEdge(body_id, source_id, .import);

    const affected = try graph.affectedFrom(std.testing.allocator, &.{source_id});
    defer std.testing.allocator.free(affected);

    try std.testing.expectEqualSlices(NodeId, &.{ body_id, backend_id }, affected);
}

test "incremental graph invalidation trace records first edge reasons" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const source_id = try graph.getOrPutNode(.{ .source_file = .{ .package = testPackage(), .path = "lib/counter.zap" } });
    const body_id = try graph.getOrPutNode(.{ .function_body = testFunctionKey() });
    const backend_id = try graph.getOrPutNode(.{ .backend_module = .{ .package = testPackage(), .module_identity = "app:counter" } });

    try graph.addEdge(body_id, source_id, .import);
    try graph.addEdge(backend_id, body_id, .backend_emission);

    const trace = try graph.affectedTraceFrom(std.testing.allocator, &.{source_id});
    defer std.testing.allocator.free(trace);

    try std.testing.expectEqual(@as(usize, 2), trace.len);
    try std.testing.expectEqual(body_id, trace[0].depender);
    try std.testing.expectEqual(source_id, trace[0].dependee);
    try std.testing.expectEqual(DependencyReason.import, trace[0].reason);
    try std.testing.expectEqual(backend_id, trace[1].depender);
    try std.testing.expectEqual(body_id, trace[1].dependee);
    try std.testing.expectEqual(DependencyReason.backend_emission, trace[1].reason);
}

test "incremental graph invalidation - body-only dependency does not imply struct surface dependency" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const source_id = try graph.getOrPutNode(.{ .source_file = .{ .package = testPackage(), .path = "lib/counter.zap" } });
    const struct_id = try graph.getOrPutNode(.{ .struct_surface = .{ .package = testPackage(), .qualified_name = "Example.Counter" } });
    const body_id = try graph.getOrPutNode(.{ .function_body = testFunctionKey() });

    try graph.addEdge(body_id, source_id, .import);

    const affected = try graph.affectedFrom(std.testing.allocator, &.{source_id});
    defer std.testing.allocator.free(affected);

    try std.testing.expectEqualSlices(NodeId, &.{body_id}, affected);
    for (affected) |id| {
        try std.testing.expect(id != struct_id);
    }
}

test "incremental graph declaration fingerprints - body-only change roots function body only" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const struct_key = NodeKey{ .struct_surface = .{ .package = testPackage(), .qualified_name = "Example.Counter" } };
    const signature_key = NodeKey{ .function_signature = testFunctionKey() };
    const body_key = NodeKey{ .function_body = testFunctionKey() };

    const struct_id = try graph.getOrPutNode(struct_key);
    const signature_id = try graph.getOrPutNode(signature_key);
    const body_id = try graph.getOrPutNode(body_key);
    try graph.addEdge(body_id, signature_id, .surface);
    try graph.addEdge(body_id, struct_id, .surface);

    const previous_records = [_]DeclarationFingerprint{
        testDeclarationFingerprint(.struct_surface, struct_key, "struct:v1"),
        testDeclarationFingerprint(.function_signature, signature_key, "sig:v1"),
        testDeclarationFingerprint(.function_body, body_key, "body:v1"),
    };
    const current_records = [_]DeclarationFingerprint{
        testDeclarationFingerprint(.struct_surface, struct_key, "struct:v1"),
        testDeclarationFingerprint(.function_signature, signature_key, "sig:v1"),
        testDeclarationFingerprint(.function_body, body_key, "body:v2"),
    };

    var selection = try selectChangedDeclarationRoots(
        std.testing.allocator,
        &graph,
        .{ .records = &previous_records },
        .{ .records = &current_records },
    );
    defer selection.deinit(std.testing.allocator);

    try std.testing.expect(selection.isPrecise());
    try std.testing.expectEqualSlices(NodeId, &.{body_id}, selection.roots);
    for (selection.roots) |root_id| {
        try std.testing.expect(root_id != struct_id);
    }
}

test "incremental graph declaration fingerprints - signature change reaches dependent bodies" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const struct_key = NodeKey{ .struct_surface = .{ .package = testPackage(), .qualified_name = "Example.Counter" } };
    const signature_key = NodeKey{ .function_signature = testFunctionKey() };
    const body_key = NodeKey{ .function_body = testFunctionKey() };
    var caller_function = testFunctionKey();
    caller_function.local_name = "call_increment";
    const caller_body_key = NodeKey{ .function_body = caller_function };

    const struct_id = try graph.getOrPutNode(struct_key);
    const signature_id = try graph.getOrPutNode(signature_key);
    const body_id = try graph.getOrPutNode(body_key);
    const caller_body_id = try graph.getOrPutNode(caller_body_key);
    try graph.addEdge(body_id, signature_id, .surface);
    try graph.addEdge(body_id, struct_id, .surface);
    try graph.addEdge(caller_body_id, signature_id, .call_edge);

    const previous_records = [_]DeclarationFingerprint{
        testDeclarationFingerprint(.struct_surface, struct_key, "struct:v1"),
        testDeclarationFingerprint(.function_signature, signature_key, "sig:v1"),
        testDeclarationFingerprint(.function_body, body_key, "body:v1"),
        testDeclarationFingerprint(.function_body, caller_body_key, "caller:v1"),
    };
    const current_records = [_]DeclarationFingerprint{
        testDeclarationFingerprint(.struct_surface, struct_key, "struct:v1"),
        testDeclarationFingerprint(.function_signature, signature_key, "sig:v2"),
        testDeclarationFingerprint(.function_body, body_key, "body:v1"),
        testDeclarationFingerprint(.function_body, caller_body_key, "caller:v1"),
    };

    var selection = try selectChangedDeclarationRoots(
        std.testing.allocator,
        &graph,
        .{ .records = &previous_records },
        .{ .records = &current_records },
    );
    defer selection.deinit(std.testing.allocator);

    try std.testing.expect(selection.isPrecise());
    try std.testing.expectEqualSlices(NodeId, &.{signature_id}, selection.roots);

    const affected = try graph.affectedFrom(std.testing.allocator, selection.roots);
    defer std.testing.allocator.free(affected);

    try std.testing.expectEqualSlices(NodeId, &.{ body_id, caller_body_id }, affected);
}

test "incremental graph declaration fingerprints - struct member change roots struct surface" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const struct_key = NodeKey{ .struct_surface = .{ .package = testPackage(), .qualified_name = "Example.Counter" } };
    const signature_key = NodeKey{ .function_signature = testFunctionKey() };
    const body_key = NodeKey{ .function_body = testFunctionKey() };

    const struct_id = try graph.getOrPutNode(struct_key);
    const signature_id = try graph.getOrPutNode(signature_key);
    const body_id = try graph.getOrPutNode(body_key);
    try graph.addEdge(signature_id, struct_id, .surface);
    try graph.addEdge(body_id, signature_id, .surface);

    const previous_records = [_]DeclarationFingerprint{
        testDeclarationFingerprint(.struct_surface, struct_key, "field:value:i64"),
        testDeclarationFingerprint(.function_signature, signature_key, "sig:v1"),
        testDeclarationFingerprint(.function_body, body_key, "body:v1"),
    };
    const current_records = [_]DeclarationFingerprint{
        testDeclarationFingerprint(.struct_surface, struct_key, "field:value:String"),
        testDeclarationFingerprint(.function_signature, signature_key, "sig:v1"),
        testDeclarationFingerprint(.function_body, body_key, "body:v1"),
    };

    var selection = try selectChangedDeclarationRoots(
        std.testing.allocator,
        &graph,
        .{ .records = &previous_records },
        .{ .records = &current_records },
    );
    defer selection.deinit(std.testing.allocator);

    try std.testing.expect(selection.isPrecise());
    try std.testing.expectEqualSlices(NodeId, &.{struct_id}, selection.roots);
}

test "incremental graph keys - specialization distinguishes same generic function by type arguments" {
    const int_bindings = [_]SpecializationBinding{
        .{ .parameter_name = "T", .value = .{ .type_identity = "Integer" } },
    };
    const string_bindings = [_]SpecializationBinding{
        .{ .parameter_name = "T", .value = .{ .type_identity = "String" } },
    };

    var int_function = testFunctionKey();
    int_function.specialization = .{ .bindings = &int_bindings };

    var string_function = testFunctionKey();
    string_function.specialization = .{ .bindings = &string_bindings };

    const int_key = NodeKey{ .function_body = int_function };
    const string_key = NodeKey{ .function_body = string_function };

    try std.testing.expect(!NodeKey.eql(int_key, string_key));
    try std.testing.expect(int_key.stableHash64() != string_key.stableHash64());

    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const int_id = try graph.getOrPutNode(int_key);
    const string_id = try graph.getOrPutNode(string_key);

    try std.testing.expect(int_id != string_id);
}

test "incremental graph - invalid node ids are rejected by accessors and graph operations" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const source_id = try graph.getOrPutNode(.{ .source_file = .{ .package = testPackage(), .path = "lib/counter.zap" } });
    const missing_id: NodeId = @enumFromInt(99);

    try std.testing.expect(graph.nodeKey(missing_id) == null);
    try std.testing.expect(graph.nodeDigest(missing_id) == null);
    try std.testing.expect(graph.nodeKind(missing_id) == null);
    try std.testing.expectError(error.UnknownIncrementalGraphNode, graph.addEdge(source_id, missing_id, .import));
    try std.testing.expectError(error.UnknownIncrementalGraphNode, graph.affectedFrom(std.testing.allocator, &.{missing_id}));
}
