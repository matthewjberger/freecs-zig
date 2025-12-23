const std = @import("std");
const ecs = @import("freecs");
const rl = @import("raylib");

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    x: f32,
    y: f32,
};

const Boid = struct {
    _: u8 = 0,
};

const BoidColor = struct {
    r: f32,
    g: f32,
    b: f32,
};

const BoidParams = struct {
    alignment_weight: f32,
    cohesion_weight: f32,
    separation_weight: f32,
    visual_range: f32,
    visual_range_sq: f32,
    min_speed: f32,
    max_speed: f32,
    paused: bool,
    mouse_attraction_weight: f32,
    mouse_repulsion_weight: f32,
    mouse_influence_range: f32,
};

const BoidData = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
};

const World = ecs.World(.{ Position, Velocity, Boid, BoidColor });
const POSITION = World.getBit(Position);
const VELOCITY = World.getBit(Velocity);
const BOID = World.getBit(Boid);
const COLOR = World.getBit(BoidColor);

const SpatialGrid = struct {
    cells: [][]BoidData,
    cell_counts: []usize,
    cell_size: f32,
    width: usize,
    height: usize,
    inv_cell: f32,
    allocator: std.mem.Allocator,

    fn create(allocator: std.mem.Allocator, screen_width: f32, screen_height: f32, cell_size: f32, max_per_cell: usize) !SpatialGrid {
        const width = @as(usize, @intFromFloat(@ceil(screen_width / cell_size)));
        const height = @as(usize, @intFromFloat(@ceil(screen_height / cell_size)));
        const total = width * height;

        const cells = try allocator.alloc([]BoidData, total);
        const cell_counts = try allocator.alloc(usize, total);
        @memset(cell_counts, 0);

        for (cells) |*cell| {
            cell.* = try allocator.alloc(BoidData, max_per_cell);
        }

        return SpatialGrid{
            .cells = cells,
            .cell_counts = cell_counts,
            .cell_size = cell_size,
            .width = width,
            .height = height,
            .inv_cell = 1.0 / cell_size,
            .allocator = allocator,
        };
    }

    fn destroy(self: *SpatialGrid) void {
        for (self.cells) |cell| {
            self.allocator.free(cell);
        }
        self.allocator.free(self.cells);
        self.allocator.free(self.cell_counts);
    }

    fn clear(self: *SpatialGrid) void {
        @memset(self.cell_counts, 0);
    }

    fn insert(self: *SpatialGrid, x: f32, y: f32, vx: f32, vy: f32) void {
        const cell_x = @min(@max(@as(usize, @intFromFloat(x * self.inv_cell)), 0), self.width - 1);
        const cell_y = @min(@max(@as(usize, @intFromFloat(y * self.inv_cell)), 0), self.height - 1);
        const idx = cell_x + cell_y * self.width;
        const count = self.cell_counts[idx];
        if (count < self.cells[idx].len) {
            self.cells[idx][count] = BoidData{ .x = x, .y = y, .vx = vx, .vy = vy };
            self.cell_counts[idx] = count + 1;
        }
    }
};

fn fastInvSqrt(x: f32) f32 {
    const xhalf = 0.5 * x;
    var i: i32 = @bitCast(x);
    i = 0x5f3759df - (i >> 1);
    var y: f32 = @bitCast(i);
    y = y * (1.5 - xhalf * y * y);
    return y;
}

const BoidCache = struct {
    positions: []Position,
    velocities: []Velocity,
    capacity: usize,
    allocator: std.mem.Allocator,

    fn create(allocator: std.mem.Allocator, capacity: usize) !BoidCache {
        return BoidCache{
            .positions = try allocator.alloc(Position, capacity),
            .velocities = try allocator.alloc(Velocity, capacity),
            .capacity = capacity,
            .allocator = allocator,
        };
    }

    fn destroy(self: *BoidCache) void {
        self.allocator.free(self.positions);
        self.allocator.free(self.velocities);
    }

    fn ensureCapacity(self: *BoidCache, needed: usize) !void {
        if (needed > self.capacity) {
            const new_cap = needed * 2;
            self.allocator.free(self.positions);
            self.allocator.free(self.velocities);
            self.positions = try self.allocator.alloc(Position, new_cap);
            self.velocities = try self.allocator.alloc(Velocity, new_cap);
            self.capacity = new_cap;
        }
    }
};

var prng: std.Random.DefaultPrng = undefined;

fn randomFloat() f32 {
    return prng.random().float(f32);
}

fn randomFloatRange(min_val: f32, max_val: f32) f32 {
    return min_val + (max_val - min_val) * randomFloat();
}

fn spawnBoids(world: *World, count: usize, screen_w: f32, screen_h: f32) !void {
    for (0..count) |_| {
        const angle = randomFloat() * std.math.pi * 2.0;
        const speed = randomFloatRange(100, 200);

        _ = try world.spawn(.{
            Position{ .x = randomFloatRange(0, screen_w), .y = randomFloatRange(0, screen_h) },
            Velocity{ .x = @cos(angle) * speed, .y = @sin(angle) * speed },
            Boid{},
            BoidColor{ .r = randomFloatRange(0.5, 1.0), .g = randomFloatRange(0.5, 1.0), .b = randomFloatRange(0.5, 1.0) },
        });
    }
}

fn processBoids(
    world: *World,
    grid: *SpatialGrid,
    cache: *BoidCache,
    params: *BoidParams,
    mouse_pos: [2]f32,
    mouse_attract: bool,
    mouse_repel: bool,
) !void {
    const MAX_NEIGHBORS = 7;
    const boid_mask = POSITION | VELOCITY | BOID;

    const entity_total = world.entityCount();
    try cache.ensureCapacity(entity_total);

    grid.clear();

    const matching = try world.getMatchingArchetypes(boid_mask, 0);
    var boid_count: usize = 0;

    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const positions = World.columnWithBit(arch, Position, POSITION);
        const velocities = World.columnWithBit(arch, Velocity, VELOCITY);
        const count = arch.entities.items.len;

        for (0..count) |i| {
            const p = positions[i];
            const v = velocities[i];
            cache.positions[boid_count] = p;
            cache.velocities[boid_count] = v;
            grid.insert(p.x, p.y, v.x, v.y);
            boid_count += 1;
        }
    }

    const visual_range_sq = params.visual_range_sq;
    const range_cells: i32 = @intFromFloat(@ceil(params.visual_range * grid.inv_cell));
    const mouse_range_sq = params.mouse_influence_range * params.mouse_influence_range;

    var boid_idx: usize = 0;
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const velocities = World.columnWithBit(arch, Velocity, VELOCITY);
        const count = arch.entities.items.len;

        for (0..count) |i| {
            const pos = cache.positions[boid_idx];
            var vel = cache.velocities[boid_idx];

            var align_x: f32 = 0;
            var align_y: f32 = 0;
            var cohesion_x: f32 = 0;
            var cohesion_y: f32 = 0;
            var sep_x: f32 = 0;
            var sep_y: f32 = 0;
            var neighbors: i32 = 0;

            const cell_x: i32 = @intFromFloat(pos.x * grid.inv_cell);
            const cell_y: i32 = @intFromFloat(pos.y * grid.inv_cell);

            var dy: i32 = -range_cells;
            outer: while (dy <= range_cells) : (dy += 1) {
                const cy = cell_y + dy;
                if (cy < 0 or cy >= @as(i32, @intCast(grid.height))) continue;

                var dx: i32 = -range_cells;
                while (dx <= range_cells) : (dx += 1) {
                    const cx = cell_x + dx;
                    if (cx < 0 or cx >= @as(i32, @intCast(grid.width))) continue;

                    const cell_idx: usize = @intCast(cx + cy * @as(i32, @intCast(grid.width)));
                    const cell_count = grid.cell_counts[cell_idx];
                    const cell = grid.cells[cell_idx];

                    for (0..cell_count) |j| {
                        const boid = cell[j];
                        const bx = boid.x - pos.x;
                        const by = boid.y - pos.y;
                        const dist_sq = bx * bx + by * by;

                        if (dist_sq > 0 and dist_sq < visual_range_sq) {
                            align_x += boid.vx;
                            align_y += boid.vy;
                            cohesion_x += boid.x;
                            cohesion_y += boid.y;
                            const inv_dist = fastInvSqrt(dist_sq);
                            sep_x -= bx * inv_dist;
                            sep_y -= by * inv_dist;
                            neighbors += 1;
                            if (neighbors >= MAX_NEIGHBORS) break :outer;
                        }
                    }
                    if (neighbors >= MAX_NEIGHBORS) break :outer;
                }
            }

            const mouse_dx = mouse_pos[0] - pos.x;
            const mouse_dy = mouse_pos[1] - pos.y;
            const mouse_dist_sq = mouse_dx * mouse_dx + mouse_dy * mouse_dy;

            if (mouse_dist_sq < mouse_range_sq) {
                const mouse_inv = fastInvSqrt(mouse_range_sq);
                const mouse_influence = 1.0 - @sqrt(mouse_dist_sq) * mouse_inv;
                if (mouse_attract) {
                    vel.x += mouse_dx * mouse_influence * params.mouse_attraction_weight;
                    vel.y += mouse_dy * mouse_influence * params.mouse_attraction_weight;
                }
                if (mouse_repel) {
                    vel.x -= mouse_dx * mouse_influence * params.mouse_repulsion_weight;
                    vel.y -= mouse_dy * mouse_influence * params.mouse_repulsion_weight;
                }
            }

            if (neighbors > 0) {
                const inv = 1.0 / @as(f32, @floatFromInt(neighbors));
                vel.x += (align_x * inv) * params.alignment_weight;
                vel.y += (align_y * inv) * params.alignment_weight;
                vel.x += (cohesion_x * inv - pos.x) * params.cohesion_weight;
                vel.y += (cohesion_y * inv - pos.y) * params.cohesion_weight;
                vel.x += sep_x * params.separation_weight;
                vel.y += sep_y * params.separation_weight;
            }

            const speed_sq = vel.x * vel.x + vel.y * vel.y;
            const max_sq = params.max_speed * params.max_speed;
            const min_sq = params.min_speed * params.min_speed;

            if (speed_sq > max_sq) {
                const f = params.max_speed * fastInvSqrt(speed_sq);
                vel.x *= f;
                vel.y *= f;
            } else if (speed_sq < min_sq and speed_sq > 0) {
                const f = params.min_speed * fastInvSqrt(speed_sq);
                vel.x *= f;
                vel.y *= f;
            }

            velocities[i] = vel;
            boid_idx += 1;
        }
    }
}

fn updatePositions(world: *World, dt: f32) !void {
    const move_mask = POSITION | VELOCITY;
    const matching = try world.getMatchingArchetypes(move_mask, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const positions = World.columnWithBit(arch, Position, POSITION);
        const velocities = World.columnWithBit(arch, Velocity, VELOCITY);
        const count = arch.entities.items.len;
        for (0..count) |i| {
            positions[i].x += velocities[i].x * dt;
            positions[i].y += velocities[i].y * dt;
        }
    }
}

fn wrapPositions(world: *World, screen_w: f32, screen_h: f32) !void {
    const matching = try world.getMatchingArchetypes(POSITION, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const positions = World.columnWithBit(arch, Position, POSITION);
        const count = arch.entities.items.len;
        for (0..count) |i| {
            if (positions[i].x < 0) {
                positions[i].x += screen_w;
            } else if (positions[i].x > screen_w) {
                positions[i].x -= screen_w;
            }
            if (positions[i].y < 0) {
                positions[i].y += screen_h;
            } else if (positions[i].y > screen_h) {
                positions[i].y -= screen_h;
            }
        }
    }
}

fn renderBoids(world: *World) !void {
    const render_mask = POSITION | VELOCITY | COLOR;
    const matching = try world.getMatchingArchetypes(render_mask, 0);

    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const positions = World.columnWithBit(arch, Position, POSITION);
        const velocities = World.columnWithBit(arch, Velocity, VELOCITY);
        const colors = World.columnWithBit(arch, BoidColor, COLOR);
        const count = arch.entities.items.len;

        for (0..count) |i| {
            const pos = positions[i];
            const vel = velocities[i];
            const col = colors[i];

            const speed_sq = vel.x * vel.x + vel.y * vel.y;
            if (speed_sq < 0.01) continue;

            const inv_speed = fastInvSqrt(speed_sq);
            const direction_x = vel.x * inv_speed;
            const direction_y = vel.y * inv_speed;

            const px = -direction_y * 4;
            const py = direction_x * 4;

            const p1 = rl.Vector2{ .x = pos.x + direction_x * 6, .y = pos.y + direction_y * 6 };
            const p2 = rl.Vector2{ .x = pos.x - direction_x * 4 + px, .y = pos.y - direction_y * 4 + py };
            const p3 = rl.Vector2{ .x = pos.x - direction_x * 4 - px, .y = pos.y - direction_y * 4 - py };

            const color = rl.Color{
                .r = @intFromFloat(col.r * 255),
                .g = @intFromFloat(col.g * 255),
                .b = @intFromFloat(col.b * 255),
                .a = 255,
            };
            rl.drawTriangle(p1, p3, p2, color);
        }
    }
}

pub fn main() !void {
    const screen_w: c_int = 1280;
    const screen_h: c_int = 720;

    prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));

    rl.initWindow(screen_w, screen_h, "Boids - Zig ECS");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    const visual_range: f32 = 50.0;
    var params = BoidParams{
        .alignment_weight = 0.5,
        .cohesion_weight = 0.3,
        .separation_weight = 0.4,
        .visual_range = visual_range,
        .visual_range_sq = visual_range * visual_range,
        .min_speed = 100.0,
        .max_speed = 300.0,
        .paused = false,
        .mouse_attraction_weight = 0.96,
        .mouse_repulsion_weight = 1.2,
        .mouse_influence_range = 150.0,
    };

    var grid = try SpatialGrid.create(allocator, @floatFromInt(screen_w), @floatFromInt(screen_h), visual_range / 2, 64);
    defer grid.destroy();

    var cache = try BoidCache.create(allocator, 2000);
    defer cache.destroy();

    try spawnBoids(&world, 1000, @floatFromInt(screen_w), @floatFromInt(screen_h));

    while (!rl.windowShouldClose()) {
        const dt: f32 = if (params.paused) 0 else rl.getFrameTime();

        const mouse = rl.getMousePosition();
        const mouse_pos = [2]f32{ mouse.x, mouse.y };
        const mouse_attract = rl.isMouseButtonDown(.left);
        const mouse_repel = rl.isMouseButtonDown(.right);

        if (rl.isKeyPressed(.space)) {
            params.paused = !params.paused;
        }

        if (rl.isKeyPressed(.equal) or rl.isKeyPressed(.kp_add)) {
            try spawnBoids(&world, 1000, @floatFromInt(screen_w), @floatFromInt(screen_h));
        }
        if (rl.isKeyPressed(.minus) or rl.isKeyPressed(.kp_subtract)) {
            var to_despawn: std.ArrayListUnmanaged(ecs.Entity) = .{};
            defer to_despawn.deinit(allocator);
            var count: usize = 0;
            outer: for (world.archetypes.items) |*arch| {
                for (arch.entities.items) |entity| {
                    if (count >= 1000) break :outer;
                    try to_despawn.append(allocator, entity);
                    count += 1;
                }
            }
            for (to_despawn.items) |entity| {
                _ = world.despawn(entity);
            }
        }

        const speed: f32 = if (rl.isKeyDown(.left_shift)) 0.01 else 0.001;
        if (rl.isKeyDown(.left)) {
            params.alignment_weight = @max(params.alignment_weight - speed, 0);
        }
        if (rl.isKeyDown(.right)) {
            params.alignment_weight = @min(params.alignment_weight + speed, 1);
        }
        if (rl.isKeyDown(.down)) {
            params.cohesion_weight = @max(params.cohesion_weight - speed, 0);
        }
        if (rl.isKeyDown(.up)) {
            params.cohesion_weight = @min(params.cohesion_weight + speed, 1);
        }

        try processBoids(&world, &grid, &cache, &params, mouse_pos, mouse_attract, mouse_repel);
        try updatePositions(&world, dt);
        try wrapPositions(&world, @floatFromInt(screen_w), @floatFromInt(screen_h));

        rl.beginDrawing();
        rl.clearBackground(rl.Color.black);

        try renderBoids(&world);

        if (mouse_attract or mouse_repel) {
            const color = if (mouse_attract) rl.Color{ .r = 0, .g = 255, .b = 0, .a = 50 } else rl.Color{ .r = 255, .g = 0, .b = 0, .a = 50 };
            rl.drawCircleLines(@intFromFloat(mouse.x), @intFromFloat(mouse.y), params.mouse_influence_range, color);
        }

        const entity_count: c_int = @intCast(world.entityCount());
        rl.drawRectangle(screen_w - 260, 0, 260, 280, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 180 });

        var y: c_int = 20;
        rl.drawText(rl.textFormat("Entities: %d", .{entity_count}), screen_w - 250, y, 20, rl.Color.white);
        y += 25;
        rl.drawText(rl.textFormat("FPS: %d", .{rl.getFPS()}), screen_w - 250, y, 20, rl.Color.white);
        y += 35;
        rl.drawText("[Space] Pause", screen_w - 250, y, 18, rl.Color.white);
        y += 22;
        rl.drawText("[+/-] Add/Remove 1000", screen_w - 250, y, 18, rl.Color.white);
        y += 22;
        rl.drawText("[Arrows] Adjust params", screen_w - 250, y, 18, rl.Color.white);
        y += 35;
        rl.drawText(rl.textFormat("Alignment: %.2f", .{params.alignment_weight}), screen_w - 250, y, 18, rl.Color.white);
        y += 22;
        rl.drawText(rl.textFormat("Cohesion: %.2f", .{params.cohesion_weight}), screen_w - 250, y, 18, rl.Color.white);
        y += 22;
        rl.drawText(rl.textFormat("Separation: %.2f", .{params.separation_weight}), screen_w - 250, y, 18, rl.Color.white);
        y += 35;
        rl.drawText("[Left Mouse] Attract", screen_w - 250, y, 18, rl.Color.white);
        y += 22;
        rl.drawText("[Right Mouse] Repel", screen_w - 250, y, 18, rl.Color.white);

        rl.endDrawing();
    }
}
