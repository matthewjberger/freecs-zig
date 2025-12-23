const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MAX_COMPONENTS: usize = 64;
const MIN_ENTITY_CAPACITY: usize = 64;

pub const Entity = struct {
    id: u32,
    generation: u32,

    pub const nil: Entity = .{ .id = 0, .generation = 0 };
};

pub const EntityLocation = struct {
    archetype_index: u32,
    row: u32,
    generation: u32,
    alive: bool,
};

pub const ComponentColumn = struct {
    data: std.ArrayListUnmanaged(u8),
    elem_size: usize,
    bit: u64,
    type_index: usize,

    pub fn init(elem_size: usize, bit: u64, type_index: usize) ComponentColumn {
        return .{
            .data = .{},
            .elem_size = elem_size,
            .bit = bit,
            .type_index = type_index,
        };
    }

    pub fn deinit(self: *ComponentColumn, allocator: Allocator) void {
        self.data.deinit(allocator);
    }
};

pub const TableEdges = struct {
    add_edges: [MAX_COMPONENTS]i32,
    remove_edges: [MAX_COMPONENTS]i32,

    pub fn init() TableEdges {
        return .{
            .add_edges = [_]i32{-1} ** MAX_COMPONENTS,
            .remove_edges = [_]i32{-1} ** MAX_COMPONENTS,
        };
    }
};

pub const Archetype = struct {
    mask: u64,
    entities: std.ArrayListUnmanaged(Entity),
    columns: std.ArrayListUnmanaged(ComponentColumn),
    column_bits: [MAX_COMPONENTS]i32,
    edges: TableEdges,

    pub fn init(mask: u64) Archetype {
        return .{
            .mask = mask,
            .entities = .{},
            .columns = .{},
            .column_bits = [_]i32{-1} ** MAX_COMPONENTS,
            .edges = TableEdges.init(),
        };
    }

    pub fn deinit(self: *Archetype, allocator: Allocator) void {
        for (self.columns.items) |*col| {
            col.deinit(allocator);
        }
        self.columns.deinit(allocator);
        self.entities.deinit(allocator);
    }
};

fn bitIndex(bit: u64) usize {
    return @ctz(bit);
}

pub fn TypeInfo(comptime ComponentTypes: anytype) type {
    return struct {
        pub const component_count = @typeInfo(@TypeOf(ComponentTypes)).@"struct".fields.len;

        pub fn getBit(comptime T: type) u64 {
            inline for (ComponentTypes, 0..) |CT, index| {
                if (CT == T) {
                    return @as(u64, 1) << @as(u6, @intCast(index));
                }
            }
            @compileError("Type not registered in World");
        }

        pub fn getSize(comptime T: type) usize {
            return @sizeOf(T);
        }

        pub fn getIndex(comptime T: type) usize {
            inline for (ComponentTypes, 0..) |CT, index| {
                if (CT == T) {
                    return index;
                }
            }
            @compileError("Type not registered in World");
        }

        pub fn getSizeByBit(bit: u64) usize {
            const index = bitIndex(bit);
            inline for (0..component_count) |i| {
                if (i == index) {
                    return @sizeOf(ComponentTypes[i]);
                }
            }
            return 0;
        }

        pub fn getMaskForTypes(comptime Types: anytype) u64 {
            var mask: u64 = 0;
            inline for (Types) |T| {
                mask |= getBit(T);
            }
            return mask;
        }
    };
}

pub fn World(comptime ComponentTypes: anytype) type {
    const TI = TypeInfo(ComponentTypes);

    return struct {
        const Self = @This();

        locations: std.ArrayListUnmanaged(EntityLocation),
        archetypes: std.ArrayListUnmanaged(Archetype),
        archetype_index: std.AutoHashMapUnmanaged(u64, usize),
        free_entities: std.ArrayListUnmanaged(Entity),
        next_entity_id: u32,
        query_cache: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(usize)),
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .locations = .{},
                .archetypes = .{},
                .archetype_index = .{},
                .free_entities = .{},
                .next_entity_id = 0,
                .query_cache = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.archetypes.items) |*arch| {
                arch.deinit(self.allocator);
            }
            self.archetypes.deinit(self.allocator);
            self.locations.deinit(self.allocator);
            self.archetype_index.deinit(self.allocator);
            self.free_entities.deinit(self.allocator);

            var cache_iter = self.query_cache.valueIterator();
            while (cache_iter.next()) |cached| {
                cached.deinit(self.allocator);
            }
            self.query_cache.deinit(self.allocator);
        }

        const TypeInfoEntry = struct {
            bit: u64,
            size: usize,
            type_index: usize,
        };

        fn findOrCreateArchetype(self: *Self, mask: u64, type_info: []const TypeInfoEntry) !usize {
            if (self.archetype_index.get(mask)) |idx| {
                return idx;
            }

            const arch_idx = self.archetypes.items.len;
            var arch = Archetype.init(mask);

            for (type_info) |entry| {
                const col_idx = arch.columns.items.len;
                arch.column_bits[bitIndex(entry.bit)] = @intCast(col_idx);
                try arch.columns.append(self.allocator, ComponentColumn.init(
                    entry.size,
                    entry.bit,
                    entry.type_index,
                ));
            }

            try self.archetypes.append(self.allocator, arch);
            try self.archetype_index.put(self.allocator, mask, arch_idx);

            var cache_iter = self.query_cache.iterator();
            while (cache_iter.next()) |entry| {
                const query_mask = entry.key_ptr.*;
                if (mask & query_mask == query_mask) {
                    try entry.value_ptr.append(self.allocator, arch_idx);
                }
            }

            for (0..MAX_COMPONENTS) |comp_bit_index| {
                const comp_mask = @as(u64, 1) << @as(u6, @intCast(comp_bit_index));
                if (TI.getSizeByBit(comp_mask) == 0) {
                    continue;
                }

                for (self.archetypes.items) |*existing| {
                    if (existing.mask | comp_mask == mask) {
                        existing.edges.add_edges[comp_bit_index] = @intCast(arch_idx);
                    }
                    if (existing.mask & ~comp_mask == mask) {
                        existing.edges.remove_edges[comp_bit_index] = @intCast(arch_idx);
                    }
                }
            }

            return arch_idx;
        }

        fn ensureEntitySlot(self: *Self, id: u32) !void {
            const current_len = self.locations.items.len;
            if (current_len > id) {
                return;
            }

            var new_cap = @max(MIN_ENTITY_CAPACITY, current_len * 2);
            while (new_cap <= id) {
                new_cap *= 2;
            }

            try self.locations.ensureTotalCapacity(self.allocator, new_cap);
            while (self.locations.items.len <= id) {
                try self.locations.append(self.allocator, .{
                    .archetype_index = 0,
                    .row = 0,
                    .generation = 0,
                    .alive = false,
                });
            }
        }

        fn allocEntity(self: *Self) !Entity {
            if (self.free_entities.items.len > 0) {
                return self.free_entities.pop().?;
            }

            const id = self.next_entity_id;
            self.next_entity_id += 1;

            try self.ensureEntitySlot(id);

            return Entity{ .id = id, .generation = 0 };
        }

        pub fn spawn(self: *Self, components: anytype) !Entity {
            const fields = @typeInfo(@TypeOf(components)).@"struct".fields;
            if (fields.len == 0) {
                return Entity.nil;
            }

            var mask: u64 = 0;
            var type_info: [fields.len]TypeInfoEntry = undefined;

            inline for (fields, 0..) |field, idx| {
                const T = field.type;
                const bit = TI.getBit(T);
                mask |= bit;
                type_info[idx] = .{
                    .bit = bit,
                    .size = @sizeOf(T),
                    .type_index = TI.getIndex(T),
                };
            }

            if (mask == 0) {
                return Entity.nil;
            }

            const arch_idx = try self.findOrCreateArchetype(mask, &type_info);
            const arch = &self.archetypes.items[arch_idx];

            const entity = try self.allocEntity();
            const row = arch.entities.items.len;
            try arch.entities.append(self.allocator, entity);

            inline for (fields) |field| {
                const T = field.type;
                const bit = TI.getBit(T);
                const col_idx_signed = arch.column_bits[bitIndex(bit)];
                if (col_idx_signed >= 0) {
                    const col_idx: usize = @intCast(col_idx_signed);
                    const col = &arch.columns.items[col_idx];
                    const old_len = col.data.items.len;
                    try col.data.resize(self.allocator, old_len + @sizeOf(T));
                    const value = @field(components, field.name);
                    const value_bytes: [*]const u8 = @ptrCast(&value);
                    @memcpy(col.data.items[old_len..][0..@sizeOf(T)], value_bytes[0..@sizeOf(T)]);
                }
            }

            self.locations.items[entity.id] = EntityLocation{
                .generation = entity.generation,
                .archetype_index = @intCast(arch_idx),
                .row = @intCast(row),
                .alive = true,
            };

            return entity;
        }

        pub fn spawnBatch(self: *Self, count: usize, comptime ComponentType: type, init_value: ComponentType) ![]Entity {
            if (count == 0) {
                return &[_]Entity{};
            }

            const bit = TI.getBit(ComponentType);
            const mask = bit;

            var type_info = [_]TypeInfoEntry{.{
                .bit = bit,
                .size = @sizeOf(ComponentType),
                .type_index = TI.getIndex(ComponentType),
            }};

            const arch_idx = try self.findOrCreateArchetype(mask, &type_info);
            const arch = &self.archetypes.items[arch_idx];

            const start_row = arch.entities.items.len;
            try arch.entities.ensureTotalCapacity(self.allocator, start_row + count);

            for (arch.columns.items) |*col| {
                try col.data.ensureTotalCapacity(self.allocator, col.data.items.len + count * col.elem_size);
            }

            var entities = try self.allocator.alloc(Entity, count);

            for (0..count) |index| {
                const entity = try self.allocEntity();
                entities[index] = entity;
                const row = start_row + index;
                try arch.entities.append(self.allocator, entity);

                for (arch.columns.items) |*col| {
                    const old_len = col.data.items.len;
                    try col.data.resize(self.allocator, old_len + col.elem_size);
                    const value_bytes: [*]const u8 = @ptrCast(&init_value);
                    @memcpy(col.data.items[old_len..][0..col.elem_size], value_bytes[0..col.elem_size]);
                }

                self.locations.items[entity.id] = EntityLocation{
                    .generation = entity.generation,
                    .archetype_index = @intCast(arch_idx),
                    .row = @intCast(row),
                    .alive = true,
                };
            }

            return entities;
        }

        pub fn spawnWithMask(self: *Self, mask: u64, count: usize) ![]Entity {
            if (mask == 0 or count == 0) {
                return &[_]Entity{};
            }

            var type_info: [MAX_COMPONENTS]TypeInfoEntry = undefined;
            var info_count: usize = 0;

            inline for (0..TI.component_count) |bit_idx| {
                const comp_bit = @as(u64, 1) << @as(u6, @intCast(bit_idx));
                if (mask & comp_bit != 0) {
                    const size = @sizeOf(ComponentTypes[bit_idx]);
                    if (size > 0) {
                        type_info[info_count] = .{
                            .bit = comp_bit,
                            .size = size,
                            .type_index = bit_idx,
                        };
                        info_count += 1;
                    }
                }
            }

            if (info_count == 0) {
                return &[_]Entity{};
            }

            const arch_idx = try self.findOrCreateArchetype(mask, type_info[0..info_count]);
            const arch = &self.archetypes.items[arch_idx];

            const start_row = arch.entities.items.len;
            try arch.entities.ensureTotalCapacity(self.allocator, start_row + count);

            for (arch.columns.items) |*col| {
                try col.data.ensureTotalCapacity(self.allocator, col.data.items.len + count * col.elem_size);
            }

            var entities = try self.allocator.alloc(Entity, count);

            for (0..count) |index| {
                const entity = try self.allocEntity();
                entities[index] = entity;
                const row = start_row + index;
                try arch.entities.append(self.allocator, entity);

                for (arch.columns.items) |*col| {
                    const old_len = col.data.items.len;
                    try col.data.resize(self.allocator, old_len + col.elem_size);
                }

                self.locations.items[entity.id] = EntityLocation{
                    .generation = entity.generation,
                    .archetype_index = @intCast(arch_idx),
                    .row = @intCast(row),
                    .alive = true,
                };
            }

            return entities;
        }

        pub fn spawnBatchWithInit(
            self: *Self,
            mask: u64,
            count: usize,
            init_callback: *const fn (arch: *Archetype, index: usize) void,
        ) ![]Entity {
            const entities = try self.spawnWithMask(mask, count);
            if (entities.len == 0) {
                return entities;
            }

            if (self.archetype_index.get(mask)) |arch_idx| {
                const arch = &self.archetypes.items[arch_idx];
                const start_row = arch.entities.items.len - count;
                for (0..count) |index| {
                    init_callback(arch, start_row + index);
                }
            }

            return entities;
        }

        pub fn despawn(self: *Self, entity: Entity) bool {
            if (entity.id >= self.locations.items.len) {
                return false;
            }

            const loc = &self.locations.items[entity.id];
            if (!loc.alive or loc.generation != entity.generation) {
                return false;
            }

            const arch = &self.archetypes.items[loc.archetype_index];
            const row: usize = loc.row;
            const last_row = arch.entities.items.len - 1;

            if (row < last_row) {
                const last_entity = arch.entities.items[last_row];
                arch.entities.items[row] = last_entity;
                self.locations.items[last_entity.id].row = @intCast(row);

                for (arch.columns.items) |*col| {
                    if (col.elem_size > 0) {
                        const src_start = last_row * col.elem_size;
                        const dst_start = row * col.elem_size;
                        @memcpy(
                            col.data.items[dst_start..][0..col.elem_size],
                            col.data.items[src_start..][0..col.elem_size],
                        );
                    }
                }
            }

            _ = arch.entities.pop();
            for (arch.columns.items) |*col| {
                if (col.elem_size > 0) {
                    col.data.shrinkRetainingCapacity(col.data.items.len - col.elem_size);
                }
            }

            loc.alive = false;
            loc.generation += 1;
            self.free_entities.append(self.allocator, Entity{ .id = entity.id, .generation = loc.generation }) catch {};

            return true;
        }

        pub fn isAlive(self: *Self, entity: Entity) bool {
            if (entity.id >= self.locations.items.len) {
                return false;
            }
            const loc = self.locations.items[entity.id];
            return loc.alive and loc.generation == entity.generation;
        }

        pub fn get(self: *Self, entity: Entity, comptime T: type) ?*T {
            if (entity.id >= self.locations.items.len) {
                return null;
            }

            const loc = self.locations.items[entity.id];
            if (!loc.alive or loc.generation != entity.generation) {
                return null;
            }

            const bit = TI.getBit(T);
            const arch = &self.archetypes.items[loc.archetype_index];
            const col_idx_signed = arch.column_bits[bitIndex(bit)];
            if (col_idx_signed < 0) {
                return null;
            }

            const col_idx: usize = @intCast(col_idx_signed);
            const col = &arch.columns.items[col_idx];
            const offset = loc.row * col.elem_size;
            return @ptrCast(@alignCast(&col.data.items[offset]));
        }

        pub fn getUnchecked(self: *Self, entity: Entity, comptime T: type) *T {
            const bit = TI.getBit(T);
            return self.getWithBit(entity, T, bit);
        }

        pub fn getWithBit(self: *Self, entity: Entity, comptime T: type, bit: u64) *T {
            const loc = self.locations.items[entity.id];
            const arch = &self.archetypes.items[loc.archetype_index];
            const col_idx: usize = @intCast(arch.column_bits[bitIndex(bit)]);
            const col = &arch.columns.items[col_idx];
            const offset = loc.row * col.elem_size;
            return @ptrCast(@alignCast(&col.data.items[offset]));
        }

        pub fn set(self: *Self, entity: Entity, value: anytype) bool {
            const T = @TypeOf(value);
            const ptr = self.get(entity, T);
            if (ptr == null) {
                return false;
            }
            ptr.?.* = value;
            return true;
        }

        pub fn has(self: *Self, entity: Entity, comptime T: type) bool {
            if (entity.id >= self.locations.items.len) {
                return false;
            }

            const loc = self.locations.items[entity.id];
            if (!loc.alive or loc.generation != entity.generation) {
                return false;
            }

            const bit = TI.getBit(T);
            const arch = &self.archetypes.items[loc.archetype_index];
            return arch.mask & bit != 0;
        }

        pub fn hasComponents(self: *Self, entity: Entity, mask: u64) bool {
            if (entity.id >= self.locations.items.len) {
                return false;
            }

            const loc = self.locations.items[entity.id];
            if (!loc.alive or loc.generation != entity.generation) {
                return false;
            }

            const arch = &self.archetypes.items[loc.archetype_index];
            return arch.mask & mask == mask;
        }

        pub fn componentMask(self: *Self, entity: Entity) ?u64 {
            if (entity.id >= self.locations.items.len) {
                return null;
            }

            const loc = self.locations.items[entity.id];
            if (!loc.alive or loc.generation != entity.generation) {
                return null;
            }

            const arch = &self.archetypes.items[loc.archetype_index];
            return arch.mask;
        }

        fn moveEntity(self: *Self, entity: Entity, from_arch_idx: usize, from_row: usize, to_arch_idx: usize) !void {
            const from_arch = &self.archetypes.items[from_arch_idx];
            const to_arch = &self.archetypes.items[to_arch_idx];

            const new_row = to_arch.entities.items.len;
            try to_arch.entities.append(self.allocator, entity);

            for (to_arch.columns.items) |*to_col| {
                const old_len = to_col.data.items.len;
                try to_col.data.resize(self.allocator, old_len + to_col.elem_size);

                const from_col_idx_signed = from_arch.column_bits[bitIndex(to_col.bit)];
                if (from_col_idx_signed >= 0) {
                    const from_col_idx: usize = @intCast(from_col_idx_signed);
                    const from_col = &from_arch.columns.items[from_col_idx];
                    const src_offset = from_row * from_col.elem_size;
                    @memcpy(
                        to_col.data.items[old_len..][0..to_col.elem_size],
                        from_col.data.items[src_offset..][0..to_col.elem_size],
                    );
                }
            }

            const last_row = from_arch.entities.items.len - 1;
            if (from_row < last_row) {
                const last_entity = from_arch.entities.items[last_row];
                from_arch.entities.items[from_row] = last_entity;
                self.locations.items[last_entity.id].row = @intCast(from_row);

                for (from_arch.columns.items) |*col| {
                    if (col.elem_size > 0) {
                        const src_start = last_row * col.elem_size;
                        const dst_start = from_row * col.elem_size;
                        @memcpy(
                            col.data.items[dst_start..][0..col.elem_size],
                            col.data.items[src_start..][0..col.elem_size],
                        );
                    }
                }
            }

            _ = from_arch.entities.pop();
            for (from_arch.columns.items) |*col| {
                if (col.elem_size > 0) {
                    col.data.shrinkRetainingCapacity(col.data.items.len - col.elem_size);
                }
            }

            self.locations.items[entity.id] = EntityLocation{
                .generation = entity.generation,
                .archetype_index = @intCast(to_arch_idx),
                .row = @intCast(new_row),
                .alive = true,
            };
        }

        pub fn addComponent(self: *Self, entity: Entity, value: anytype) !bool {
            const T = @TypeOf(value);

            if (entity.id >= self.locations.items.len) {
                return false;
            }

            const loc = self.locations.items[entity.id];
            if (!loc.alive or loc.generation != entity.generation) {
                return false;
            }

            const bit = TI.getBit(T);
            const bit_idx = bitIndex(bit);

            const arch = &self.archetypes.items[loc.archetype_index];

            if (arch.mask & bit != 0) {
                const col_idx: usize = @intCast(arch.column_bits[bit_idx]);
                const col = &arch.columns.items[col_idx];
                const offset = loc.row * col.elem_size;
                const ptr: *T = @ptrCast(@alignCast(&col.data.items[offset]));
                ptr.* = value;
                return true;
            }

            const new_mask = arch.mask | bit;
            var target_arch_idx_signed = arch.edges.add_edges[bit_idx];

            if (target_arch_idx_signed < 0) {
                var type_info: [MAX_COMPONENTS]TypeInfoEntry = undefined;
                var info_count: usize = 0;

                for (arch.columns.items) |*col| {
                    type_info[info_count] = .{
                        .bit = col.bit,
                        .size = col.elem_size,
                        .type_index = col.type_index,
                    };
                    info_count += 1;
                }
                type_info[info_count] = .{
                    .bit = bit,
                    .size = @sizeOf(T),
                    .type_index = TI.getIndex(T),
                };
                info_count += 1;

                target_arch_idx_signed = @intCast(try self.findOrCreateArchetype(new_mask, type_info[0..info_count]));
                self.archetypes.items[loc.archetype_index].edges.add_edges[bit_idx] = target_arch_idx_signed;
            }

            const target_arch_idx: usize = @intCast(target_arch_idx_signed);
            try self.moveEntity(entity, loc.archetype_index, loc.row, target_arch_idx);

            const new_loc = self.locations.items[entity.id];
            const to_arch = &self.archetypes.items[new_loc.archetype_index];
            const col_idx: usize = @intCast(to_arch.column_bits[bit_idx]);
            const col = &to_arch.columns.items[col_idx];
            const offset = new_loc.row * col.elem_size;
            const ptr: *T = @ptrCast(@alignCast(&col.data.items[offset]));
            ptr.* = value;

            return true;
        }

        pub fn removeComponent(self: *Self, entity: Entity, comptime T: type) !bool {
            if (entity.id >= self.locations.items.len) {
                return false;
            }

            const loc = self.locations.items[entity.id];
            if (!loc.alive or loc.generation != entity.generation) {
                return false;
            }

            const bit = TI.getBit(T);
            const bit_idx = bitIndex(bit);
            const arch = &self.archetypes.items[loc.archetype_index];

            if (arch.mask & bit == 0) {
                return false;
            }

            const new_mask = arch.mask & ~bit;

            if (new_mask == 0) {
                _ = self.despawn(entity);
                return true;
            }

            var target_arch_idx_signed = arch.edges.remove_edges[bit_idx];

            if (target_arch_idx_signed < 0) {
                var type_info: [MAX_COMPONENTS]TypeInfoEntry = undefined;
                var info_count: usize = 0;

                for (arch.columns.items) |*col| {
                    if (col.bit != bit) {
                        type_info[info_count] = .{
                            .bit = col.bit,
                            .size = col.elem_size,
                            .type_index = col.type_index,
                        };
                        info_count += 1;
                    }
                }

                target_arch_idx_signed = @intCast(try self.findOrCreateArchetype(new_mask, type_info[0..info_count]));
                self.archetypes.items[loc.archetype_index].edges.remove_edges[bit_idx] = target_arch_idx_signed;
            }

            const target_arch_idx: usize = @intCast(target_arch_idx_signed);
            try self.moveEntity(entity, loc.archetype_index, loc.row, target_arch_idx);

            return true;
        }

        pub fn getMatchingArchetypes(self: *Self, mask: u64, exclude: u64) ![]usize {
            const cache_key = mask | (exclude << 32);
            if (self.query_cache.get(cache_key)) |cached| {
                return cached.items;
            }

            var matching: std.ArrayListUnmanaged(usize) = .{};
            for (self.archetypes.items, 0..) |arch, idx| {
                if (arch.mask & mask == mask and (exclude == 0 or arch.mask & exclude == 0)) {
                    try matching.append(self.allocator, idx);
                }
            }
            try self.query_cache.put(self.allocator, cache_key, matching);
            return matching.items;
        }

        pub fn queryCount(self: *Self, mask: u64, exclude: u64) !usize {
            var count: usize = 0;
            const matching = try self.getMatchingArchetypes(mask, exclude);
            for (matching) |arch_idx| {
                count += self.archetypes.items[arch_idx].entities.items.len;
            }
            return count;
        }

        pub fn queryEntities(self: *Self, mask: u64, exclude: u64) !std.ArrayListUnmanaged(Entity) {
            var entities: std.ArrayListUnmanaged(Entity) = .{};
            const matching = try self.getMatchingArchetypes(mask, exclude);
            for (matching) |arch_idx| {
                const arch = &self.archetypes.items[arch_idx];
                for (arch.entities.items) |entity| {
                    try entities.append(self.allocator, entity);
                }
            }
            return entities;
        }

        pub fn queryFirst(self: *Self, mask: u64, exclude: u64) !?Entity {
            const matching = try self.getMatchingArchetypes(mask, exclude);
            for (matching) |arch_idx| {
                const arch = &self.archetypes.items[arch_idx];
                if (arch.entities.items.len > 0) {
                    return arch.entities.items[0];
                }
            }
            return null;
        }

        pub fn entityCount(self: *Self) usize {
            var count: usize = 0;
            for (self.archetypes.items) |arch| {
                count += arch.entities.items.len;
            }
            return count;
        }

        pub fn despawnBatch(self: *Self, entities: []const Entity) usize {
            var count: usize = 0;
            for (entities) |entity| {
                if (self.despawn(entity)) {
                    count += 1;
                }
            }
            return count;
        }

        pub fn reserveEntities(self: *Self, count: usize) !void {
            try self.locations.ensureTotalCapacity(self.allocator, self.locations.items.len + count);
        }

        pub fn column(arch: *Archetype, comptime T: type) ?[]T {
            const bit = TI.getBit(T);
            const col_idx_signed = arch.column_bits[bitIndex(bit)];
            if (col_idx_signed < 0) {
                return null;
            }

            const col_idx: usize = @intCast(col_idx_signed);
            const col = &arch.columns.items[col_idx];
            const count = arch.entities.items.len;
            if (count == 0 or col.data.items.len == 0) {
                return null;
            }

            const bytes = col.data.items[0 .. count * @sizeOf(T)];
            const aligned: []align(@alignOf(T)) u8 = @alignCast(bytes);
            return std.mem.bytesAsSlice(T, aligned);
        }

        pub fn columnUnchecked(arch: *Archetype, comptime T: type) []T {
            const bit = TI.getBit(T);
            return columnWithBit(arch, T, bit);
        }

        pub fn columnWithBit(arch: *Archetype, comptime T: type, bit: u64) []T {
            const col_idx: usize = @intCast(arch.column_bits[bitIndex(bit)]);
            const col = &arch.columns.items[col_idx];
            const count = arch.entities.items.len;
            const bytes = col.data.items[0 .. count * @sizeOf(T)];
            const aligned: []align(@alignOf(T)) u8 = @alignCast(bytes);
            return std.mem.bytesAsSlice(T, aligned);
        }

        pub const TableIterator = struct {
            world: *Self,
            mask: u64,
            exclude: u64,
            indices: []usize,
            current: usize,

            pub const Result = struct {
                archetype: *Archetype,
                index: usize,
            };

            pub fn next(iter: *TableIterator) ?Result {
                if (iter.current >= iter.indices.len) {
                    return null;
                }
                const arch_idx = iter.indices[iter.current];
                iter.current += 1;
                return .{
                    .archetype = &iter.world.archetypes.items[arch_idx],
                    .index = arch_idx,
                };
            }
        };

        pub fn tableIterator(self: *Self, mask: u64, exclude: u64) !TableIterator {
            return TableIterator{
                .world = self,
                .mask = mask,
                .exclude = exclude,
                .indices = try self.getMatchingArchetypes(mask, exclude),
                .current = 0,
            };
        }

        pub fn forEach(
            self: *Self,
            mask: u64,
            callback: *const fn (arch: *Archetype, index: usize) void,
            exclude: u64,
        ) !void {
            const matching = try self.getMatchingArchetypes(mask, exclude);
            for (matching) |arch_idx| {
                const arch = &self.archetypes.items[arch_idx];
                for (0..arch.entities.items.len) |index| {
                    callback(arch, index);
                }
            }
        }

        pub fn forEachTable(
            self: *Self,
            mask: u64,
            callback: *const fn (arch: *Archetype) void,
            exclude: u64,
        ) !void {
            const matching = try self.getMatchingArchetypes(mask, exclude);
            for (matching) |arch_idx| {
                callback(&self.archetypes.items[arch_idx]);
            }
        }

        pub fn getBit(comptime T: type) u64 {
            return TI.getBit(T);
        }

        pub fn getMaskForTypes(comptime Types: anytype) u64 {
            return TI.getMaskForTypes(Types);
        }
    };
}

const testing = std.testing;

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    x: f32,
    y: f32,
};

const Health = struct {
    value: f32,
};

const TestWorld = World(.{ Position, Velocity, Health });

test "spawn entity" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{ Position{ .x = 1, .y = 2 }, Velocity{ .x = 3, .y = 4 } });

    try testing.expectEqual(@as(u32, 0), entity.id);
    try testing.expectEqual(@as(u32, 0), entity.generation);
    try testing.expectEqual(@as(usize, 1), world.entityCount());
}

test "get component" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{ Position{ .x = 1, .y = 2 }, Velocity{ .x = 3, .y = 4 } });

    const pos = world.get(entity, Position);
    try testing.expect(pos != null);
    try testing.expectEqual(@as(f32, 1), pos.?.x);
    try testing.expectEqual(@as(f32, 2), pos.?.y);

    const vel = world.get(entity, Velocity);
    try testing.expect(vel != null);
    try testing.expectEqual(@as(f32, 3), vel.?.x);
    try testing.expectEqual(@as(f32, 4), vel.?.y);

    const health = world.get(entity, Health);
    try testing.expect(health == null);
}

test "set component" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{Position{ .x = 1, .y = 2 }});

    _ = world.set(entity, Position{ .x = 10, .y = 20 });

    const pos = world.get(entity, Position);
    try testing.expectEqual(@as(f32, 10), pos.?.x);
    try testing.expectEqual(@as(f32, 20), pos.?.y);
}

test "modify component" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{Position{ .x = 1, .y = 2 }});

    const pos = world.get(entity, Position);
    pos.?.x = 100;
    pos.?.y = 200;

    const pos2 = world.get(entity, Position);
    try testing.expectEqual(@as(f32, 100), pos2.?.x);
    try testing.expectEqual(@as(f32, 200), pos2.?.y);
}

test "despawn entity" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const e1 = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    const e2 = try world.spawn(.{Position{ .x = 2, .y = 2 }});
    const e3 = try world.spawn(.{Position{ .x = 3, .y = 3 }});

    try testing.expectEqual(@as(usize, 3), world.entityCount());

    _ = world.despawn(e2);

    try testing.expectEqual(@as(usize, 2), world.entityCount());
    try testing.expect(world.isAlive(e1));
    try testing.expect(!world.isAlive(e2));
    try testing.expect(world.isAlive(e3));

    try testing.expect(world.get(e2, Position) == null);
}

test "generational indices" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const e1 = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    try testing.expectEqual(@as(u32, 0), e1.generation);

    const id = e1.id;
    _ = world.despawn(e1);

    const e2 = try world.spawn(.{Position{ .x = 2, .y = 2 }});
    try testing.expectEqual(id, e2.id);
    try testing.expectEqual(@as(u32, 1), e2.generation);

    try testing.expect(world.get(e1, Position) == null);

    const pos = world.get(e2, Position);
    try testing.expect(pos != null);
    try testing.expectEqual(@as(f32, 2), pos.?.x);
}

test "multiple archetypes" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const e1 = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    const e2 = try world.spawn(.{ Position{ .x = 2, .y = 2 }, Velocity{ .x = 1, .y = 0 } });
    const e3 = try world.spawn(.{ Position{ .x = 3, .y = 3 }, Velocity{ .x = 0, .y = 1 }, Health{ .value = 100 } });

    try testing.expectEqual(@as(usize, 3), world.archetypes.items.len);

    try testing.expect(world.has(e1, Position));
    try testing.expect(!world.has(e1, Velocity));

    try testing.expect(world.has(e2, Position));
    try testing.expect(world.has(e2, Velocity));
    try testing.expect(!world.has(e2, Health));

    try testing.expect(world.has(e3, Position));
    try testing.expect(world.has(e3, Velocity));
    try testing.expect(world.has(e3, Health));
}

test "query count" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    _ = try world.spawn(.{Position{ .x = 2, .y = 2 }});
    _ = try world.spawn(.{ Position{ .x = 3, .y = 3 }, Velocity{ .x = 1, .y = 0 } });
    _ = try world.spawn(.{ Position{ .x = 4, .y = 4 }, Velocity{ .x = 0, .y = 1 }, Health{ .value = 100 } });

    const POSITION = TestWorld.getBit(Position);
    const VELOCITY = TestWorld.getBit(Velocity);
    const HEALTH = TestWorld.getBit(Health);

    try testing.expectEqual(@as(usize, 4), try world.queryCount(POSITION, 0));
    try testing.expectEqual(@as(usize, 2), try world.queryCount(VELOCITY, 0));
    try testing.expectEqual(@as(usize, 1), try world.queryCount(HEALTH, 0));
    try testing.expectEqual(@as(usize, 2), try world.queryCount(POSITION | VELOCITY, 0));
}

test "column iteration" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.spawn(.{ Position{ .x = 1, .y = 0 }, Velocity{ .x = 10, .y = 0 } });
    _ = try world.spawn(.{ Position{ .x = 2, .y = 0 }, Velocity{ .x = 20, .y = 0 } });
    _ = try world.spawn(.{ Position{ .x = 3, .y = 0 }, Velocity{ .x = 30, .y = 0 } });

    try testing.expectEqual(@as(usize, 3), world.entityCount());
    try testing.expectEqual(@as(usize, 1), world.archetypes.items.len);

    const POSITION = TestWorld.getBit(Position);
    const VELOCITY = TestWorld.getBit(Velocity);

    const arch = &world.archetypes.items[0];
    try testing.expectEqual(POSITION | VELOCITY, arch.mask);
    try testing.expectEqual(@as(usize, 3), arch.entities.items.len);

    const positions = TestWorld.column(arch, Position);
    const velocities = TestWorld.column(arch, Velocity);

    try testing.expect(positions != null);
    try testing.expect(velocities != null);
    try testing.expectEqual(@as(usize, 3), positions.?.len);
    try testing.expectEqual(@as(usize, 3), velocities.?.len);

    try testing.expectEqual(@as(f32, 1), positions.?[0].x);
    try testing.expectEqual(@as(f32, 2), positions.?[1].x);
    try testing.expectEqual(@as(f32, 3), positions.?[2].x);

    const dt: f32 = 1.0;
    for (positions.?, velocities.?) |*pos, vel| {
        pos.x += vel.x * dt;
    }

    try testing.expectEqual(@as(f32, 11), positions.?[0].x);
    try testing.expectEqual(@as(f32, 22), positions.?[1].x);
    try testing.expectEqual(@as(f32, 33), positions.?[2].x);
}

test "data integrity after despawn" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const e1 = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    const e2 = try world.spawn(.{Position{ .x = 2, .y = 2 }});
    const e3 = try world.spawn(.{Position{ .x = 3, .y = 3 }});

    _ = world.despawn(e2);

    const pos1 = world.get(e1, Position);
    const pos3 = world.get(e3, Position);

    try testing.expect(pos1 != null);
    try testing.expectEqual(@as(f32, 1), pos1.?.x);
    try testing.expect(pos3 != null);
    try testing.expectEqual(@as(f32, 3), pos3.?.x);
}

test "spawn many" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var entities: [100]Entity = undefined;
    for (0..100) |i| {
        entities[i] = try world.spawn(.{Position{ .x = @floatFromInt(i), .y = @floatFromInt(i) }});
    }

    try testing.expectEqual(@as(usize, 100), world.entityCount());

    for (0..100) |i| {
        const pos = world.get(entities[i], Position);
        try testing.expect(pos != null);
        try testing.expectEqual(@as(f32, @floatFromInt(i)), pos.?.x);
    }
}

test "despawn and respawn" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var entities: [10]Entity = undefined;
    for (0..10) |i| {
        entities[i] = try world.spawn(.{Position{ .x = @floatFromInt(i), .y = 0 }});
    }

    for (0..5) |i| {
        _ = world.despawn(entities[i * 2]);
    }

    try testing.expectEqual(@as(usize, 5), world.entityCount());

    var new_entities: [5]Entity = undefined;
    for (0..5) |i| {
        new_entities[i] = try world.spawn(.{Position{ .x = @floatFromInt(i + 100), .y = 0 }});
    }

    try testing.expectEqual(@as(usize, 10), world.entityCount());

    for (0..5) |i| {
        try testing.expectEqual(@as(u32, 1), new_entities[i].generation);
    }
}

test "has component" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{Position{ .x = 1, .y = 2 }});

    try testing.expect(world.has(entity, Position));
    try testing.expect(!world.has(entity, Velocity));
    try testing.expect(!world.has(entity, Health));
}

test "add component" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{Position{ .x = 1, .y = 2 }});

    try testing.expect(!world.has(entity, Velocity));

    _ = try world.addComponent(entity, Velocity{ .x = 5, .y = 6 });

    try testing.expect(world.has(entity, Velocity));
    const vel = world.get(entity, Velocity);
    try testing.expect(vel != null);
    try testing.expectEqual(@as(f32, 5), vel.?.x);
    try testing.expectEqual(@as(f32, 6), vel.?.y);

    const pos = world.get(entity, Position);
    try testing.expect(pos != null);
    try testing.expectEqual(@as(f32, 1), pos.?.x);
    try testing.expectEqual(@as(f32, 2), pos.?.y);
}

test "remove component" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{ Position{ .x = 1, .y = 2 }, Velocity{ .x = 3, .y = 4 } });

    try testing.expect(world.has(entity, Velocity));

    _ = try world.removeComponent(entity, Velocity);

    try testing.expect(!world.has(entity, Velocity));
    try testing.expect(world.has(entity, Position));

    const pos = world.get(entity, Position);
    try testing.expect(pos != null);
    try testing.expectEqual(@as(f32, 1), pos.?.x);
    try testing.expectEqual(@as(f32, 2), pos.?.y);
}

test "query with exclude" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    _ = try world.spawn(.{ Position{ .x = 2, .y = 2 }, Velocity{ .x = 1, .y = 0 } });
    _ = try world.spawn(.{ Position{ .x = 3, .y = 3 }, Velocity{ .x = 0, .y = 1 }, Health{ .value = 100 } });

    const POSITION = TestWorld.getBit(Position);
    const VELOCITY = TestWorld.getBit(Velocity);
    const HEALTH = TestWorld.getBit(Health);

    const count_with_pos = try world.queryCount(POSITION, 0);
    try testing.expectEqual(@as(usize, 3), count_with_pos);

    const count_pos_without_vel = try world.queryCount(POSITION, VELOCITY);
    try testing.expectEqual(@as(usize, 1), count_pos_without_vel);

    const count_pos_without_health = try world.queryCount(POSITION, HEALTH);
    try testing.expectEqual(@as(usize, 2), count_pos_without_health);
}

test "spawn with mask" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const POSITION = TestWorld.getBit(Position);
    const VELOCITY = TestWorld.getBit(Velocity);

    const entities = try world.spawnWithMask(POSITION | VELOCITY, 5);
    defer world.allocator.free(entities);

    try testing.expectEqual(@as(usize, 5), entities.len);
    try testing.expectEqual(@as(usize, 5), world.entityCount());

    for (entities) |entity| {
        try testing.expect(world.has(entity, Position));
        try testing.expect(world.has(entity, Velocity));
    }
}

test "query first" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const POSITION = TestWorld.getBit(Position);
    const VELOCITY = TestWorld.getBit(Velocity);
    const HEALTH = TestWorld.getBit(Health);

    var entity = try world.queryFirst(POSITION, 0);
    try testing.expect(entity == null);

    _ = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    _ = try world.spawn(.{ Position{ .x = 2, .y = 2 }, Velocity{ .x = 1, .y = 0 } });

    entity = try world.queryFirst(POSITION, 0);
    try testing.expect(entity != null);

    entity = try world.queryFirst(HEALTH, 0);
    try testing.expect(entity == null);

    entity = try world.queryFirst(POSITION | VELOCITY, 0);
    try testing.expect(entity != null);
}

test "has components mask" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{ Position{ .x = 1, .y = 2 }, Velocity{ .x = 3, .y = 4 } });

    const POSITION = TestWorld.getBit(Position);
    const VELOCITY = TestWorld.getBit(Velocity);
    const HEALTH = TestWorld.getBit(Health);

    try testing.expect(world.hasComponents(entity, POSITION));
    try testing.expect(world.hasComponents(entity, VELOCITY));
    try testing.expect(world.hasComponents(entity, POSITION | VELOCITY));
    try testing.expect(!world.hasComponents(entity, HEALTH));
    try testing.expect(!world.hasComponents(entity, POSITION | HEALTH));
}

test "component mask" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{ Position{ .x = 1, .y = 2 }, Velocity{ .x = 3, .y = 4 } });

    const POSITION = TestWorld.getBit(Position);
    const VELOCITY = TestWorld.getBit(Velocity);

    const mask = world.componentMask(entity);
    try testing.expect(mask != null);
    try testing.expectEqual(POSITION | VELOCITY, mask.?);
}

test "table edges cache" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const e1 = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    _ = try world.addComponent(e1, Velocity{ .x = 2, .y = 2 });

    const e2 = try world.spawn(.{Position{ .x = 3, .y = 3 }});
    _ = try world.addComponent(e2, Velocity{ .x = 4, .y = 4 });

    try testing.expect(world.has(e1, Velocity));
    try testing.expect(world.has(e2, Velocity));

    const pos1 = world.get(e1, Position);
    const pos2 = world.get(e2, Position);
    try testing.expect(pos1 != null);
    try testing.expectEqual(@as(f32, 1), pos1.?.x);
    try testing.expect(pos2 != null);
    try testing.expectEqual(@as(f32, 3), pos2.?.x);

    const vel1 = world.get(e1, Velocity);
    const vel2 = world.get(e2, Velocity);
    try testing.expect(vel1 != null);
    try testing.expectEqual(@as(f32, 2), vel1.?.x);
    try testing.expect(vel2 != null);
    try testing.expectEqual(@as(f32, 4), vel2.?.x);
}

test "get with bit" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const POSITION = TestWorld.getBit(Position);

    const entity = try world.spawn(.{Position{ .x = 42, .y = 99 }});

    const pos = world.getWithBit(entity, Position, POSITION);
    try testing.expectEqual(@as(f32, 42), pos.x);
    try testing.expectEqual(@as(f32, 99), pos.y);
}

test "column with bit" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const POSITION = TestWorld.getBit(Position);

    _ = try world.spawn(.{Position{ .x = 1, .y = 2 }});
    _ = try world.spawn(.{Position{ .x = 3, .y = 4 }});

    const arch = &world.archetypes.items[0];
    const positions = TestWorld.columnWithBit(arch, Position, POSITION);

    try testing.expectEqual(@as(usize, 2), positions.len);
    try testing.expectEqual(@as(f32, 1), positions[0].x);
    try testing.expectEqual(@as(f32, 3), positions[1].x);
}

test "table iterator with index" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    _ = try world.spawn(.{ Position{ .x = 2, .y = 2 }, Velocity{ .x = 1, .y = 0 } });

    const POSITION = TestWorld.getBit(Position);

    var iter = try world.tableIterator(POSITION, 0);
    var count: usize = 0;
    while (iter.next()) |result| {
        try testing.expect(result.archetype.mask & POSITION != 0);
        try testing.expect(result.index < world.archetypes.items.len);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "spawn batch with init" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const POSITION = TestWorld.getBit(Position);

    const initPos = struct {
        fn call(arch: *Archetype, index: usize) void {
            const positions = TestWorld.column(arch, Position).?;
            positions[index] = Position{ .x = @floatFromInt(index * 10), .y = @floatFromInt(index * 20) };
        }
    }.call;

    const entities = try world.spawnBatchWithInit(POSITION, 3, initPos);
    defer world.allocator.free(entities);

    try testing.expectEqual(@as(usize, 3), entities.len);

    const pos0 = world.get(entities[0], Position);
    const pos1 = world.get(entities[1], Position);
    const pos2 = world.get(entities[2], Position);

    try testing.expect(pos0 != null);
    try testing.expect(pos1 != null);
    try testing.expect(pos2 != null);
    try testing.expectEqual(@as(f32, 0), pos0.?.x);
    try testing.expectEqual(@as(f32, 10), pos1.?.x);
    try testing.expectEqual(@as(f32, 20), pos2.?.x);
}

test "despawn batch" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var entities: [5]Entity = undefined;
    for (0..5) |i| {
        entities[i] = try world.spawn(.{Position{ .x = @floatFromInt(i), .y = 0 }});
    }

    try testing.expectEqual(@as(usize, 5), world.entityCount());

    const despawned = world.despawnBatch(entities[1..4]);
    try testing.expectEqual(@as(usize, 3), despawned);
    try testing.expectEqual(@as(usize, 2), world.entityCount());

    try testing.expect(world.isAlive(entities[0]));
    try testing.expect(!world.isAlive(entities[1]));
    try testing.expect(!world.isAlive(entities[2]));
    try testing.expect(!world.isAlive(entities[3]));
    try testing.expect(world.isAlive(entities[4]));
}

test "reserve entities" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    try world.reserveEntities(1000);

    try testing.expect(world.locations.capacity >= 1000);
}

test "forEach callback" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.spawn(.{Position{ .x = 1, .y = 0 }});
    _ = try world.spawn(.{Position{ .x = 2, .y = 0 }});
    _ = try world.spawn(.{Position{ .x = 3, .y = 0 }});

    const POSITION = TestWorld.getBit(Position);

    const Callback = struct {
        var sum: f32 = 0;
        fn call(arch: *Archetype, index: usize) void {
            const positions = TestWorld.column(arch, Position).?;
            sum += positions[index].x;
        }
    };

    Callback.sum = 0;
    try world.forEach(POSITION, Callback.call, 0);
    try testing.expectEqual(@as(f32, 6), Callback.sum);
}

test "forEachTable callback" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.spawn(.{Position{ .x = 10, .y = 0 }});
    _ = try world.spawn(.{Position{ .x = 20, .y = 0 }});
    _ = try world.spawn(.{ Position{ .x = 30, .y = 0 }, Velocity{ .x = 1, .y = 0 } });

    const POSITION = TestWorld.getBit(Position);

    const TableCallback = struct {
        var table_count: usize = 0;
        var entity_count: usize = 0;
        fn call(arch: *Archetype) void {
            table_count += 1;
            entity_count += arch.entities.items.len;
        }
    };

    TableCallback.table_count = 0;
    TableCallback.entity_count = 0;
    try world.forEachTable(POSITION, TableCallback.call, 0);
    try testing.expectEqual(@as(usize, 2), TableCallback.table_count);
    try testing.expectEqual(@as(usize, 3), TableCallback.entity_count);
}

test "getUnchecked performance path" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{ Position{ .x = 42, .y = 99 }, Velocity{ .x = 1, .y = 2 } });

    const pos = world.getUnchecked(entity, Position);
    try testing.expectEqual(@as(f32, 42), pos.x);
    try testing.expectEqual(@as(f32, 99), pos.y);

    pos.x = 100;
    const pos2 = world.get(entity, Position);
    try testing.expectEqual(@as(f32, 100), pos2.?.x);
}

test "columnUnchecked" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.spawn(.{ Position{ .x = 1, .y = 2 }, Velocity{ .x = 10, .y = 20 } });
    _ = try world.spawn(.{ Position{ .x = 3, .y = 4 }, Velocity{ .x = 30, .y = 40 } });

    const arch = &world.archetypes.items[0];
    const positions = TestWorld.columnUnchecked(arch, Position);
    const velocities = TestWorld.columnUnchecked(arch, Velocity);

    try testing.expectEqual(@as(usize, 2), positions.len);
    try testing.expectEqual(@as(usize, 2), velocities.len);
    try testing.expectEqual(@as(f32, 1), positions[0].x);
    try testing.expectEqual(@as(f32, 10), velocities[0].x);
}

test "query entities collection" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const e1 = try world.spawn(.{Position{ .x = 1, .y = 0 }});
    const e2 = try world.spawn(.{Position{ .x = 2, .y = 0 }});
    _ = try world.spawn(.{Velocity{ .x = 0, .y = 0 }});

    const POSITION = TestWorld.getBit(Position);

    var entities = try world.queryEntities(POSITION, 0);
    defer entities.deinit(world.allocator);

    try testing.expectEqual(@as(usize, 2), entities.items.len);
    try testing.expect(entities.items[0].id == e1.id or entities.items[0].id == e2.id);
}

test "add existing component updates value" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{Position{ .x = 1, .y = 2 }});

    _ = try world.addComponent(entity, Position{ .x = 100, .y = 200 });

    const pos = world.get(entity, Position);
    try testing.expect(pos != null);
    try testing.expectEqual(@as(f32, 100), pos.?.x);
    try testing.expectEqual(@as(f32, 200), pos.?.y);
}

test "remove last component despawns entity" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{Position{ .x = 1, .y = 2 }});
    try testing.expect(world.isAlive(entity));

    _ = try world.removeComponent(entity, Position);

    try testing.expect(!world.isAlive(entity));
}

test "spawn batch single component" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entities = try world.spawnBatch(5, Position, Position{ .x = 42, .y = 99 });
    defer world.allocator.free(entities);

    try testing.expectEqual(@as(usize, 5), entities.len);
    try testing.expectEqual(@as(usize, 5), world.entityCount());

    for (entities) |entity| {
        const pos = world.get(entity, Position);
        try testing.expect(pos != null);
        try testing.expectEqual(@as(f32, 42), pos.?.x);
        try testing.expectEqual(@as(f32, 99), pos.?.y);
    }
}
