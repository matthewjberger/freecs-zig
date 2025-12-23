const std = @import("std");
const ecs = @import("freecs");
const rl = @import("raylib");

const TowerType = enum {
    basic,
    frost,
    cannon,
    sniper,
    poison,

    fn cost(self: TowerType) u32 {
        return switch (self) {
            .basic => 60,
            .frost => 120,
            .cannon => 200,
            .sniper => 180,
            .poison => 150,
        };
    }

    fn upgradeCost(self: TowerType, current_level: u32) u32 {
        return @intFromFloat(@as(f32, @floatFromInt(self.cost())) * 0.5 * @as(f32, @floatFromInt(current_level)));
    }

    fn damage(self: TowerType, level: u32) f32 {
        const base: f32 = switch (self) {
            .basic => 15.0,
            .frost => 8.0,
            .cannon => 50.0,
            .sniper => 80.0,
            .poison => 5.0,
        };
        return base * (1.0 + 0.25 * @as(f32, @floatFromInt(level - 1)));
    }

    fn range(self: TowerType, level: u32) f32 {
        const base: f32 = switch (self) {
            .basic => 100.0,
            .frost => 80.0,
            .cannon => 120.0,
            .sniper => 180.0,
            .poison => 90.0,
        };
        return base * (1.0 + 0.15 * @as(f32, @floatFromInt(level - 1)));
    }

    fn fireRate(self: TowerType, level: u32) f32 {
        const base: f32 = switch (self) {
            .basic => 0.5,
            .frost => 1.0,
            .cannon => 2.0,
            .sniper => 3.0,
            .poison => 0.8,
        };
        return base * @max(1.0 - 0.1 * @as(f32, @floatFromInt(level - 1)), 0.2);
    }

    fn color(self: TowerType) rl.Color {
        return switch (self) {
            .basic => rl.Color.green,
            .frost => rl.Color{ .r = 51, .g = 153, .b = 255, .a = 255 },
            .cannon => rl.Color.red,
            .sniper => rl.Color.dark_gray,
            .poison => rl.Color{ .r = 153, .g = 51, .b = 204, .a = 255 },
        };
    }

    fn projectileSpeed(self: TowerType) f32 {
        return switch (self) {
            .basic => 300.0,
            .frost => 200.0,
            .cannon => 250.0,
            .sniper => 500.0,
            .poison => 250.0,
        };
    }
};

const GameState = enum {
    waiting_for_wave,
    wave_in_progress,
    game_over,
    victory,
    paused,
};

const EnemyType = enum {
    normal,
    fast,
    tank,
    flying,
    shielded,
    healer,
    boss,

    fn baseHealth(self: EnemyType) f32 {
        return switch (self) {
            .normal => 50.0,
            .fast => 30.0,
            .tank => 150.0,
            .flying => 40.0,
            .shielded => 80.0,
            .healer => 60.0,
            .boss => 500.0,
        };
    }

    fn health(self: EnemyType, wave: u32) f32 {
        const health_multiplier = 1.0 + (@as(f32, @floatFromInt(wave)) - 1.0) * 0.5;
        return self.baseHealth() * health_multiplier;
    }

    fn speed(self: EnemyType) f32 {
        return switch (self) {
            .normal => 40.0,
            .fast => 80.0,
            .tank => 20.0,
            .flying => 60.0,
            .shielded => 30.0,
            .healer => 35.0,
            .boss => 15.0,
        };
    }

    fn value(self: EnemyType, wave: u32) u32 {
        const base: u32 = switch (self) {
            .normal => 10,
            .fast => 15,
            .tank => 30,
            .flying => 20,
            .shielded => 25,
            .healer => 40,
            .boss => 100,
        };
        return base + wave * 2;
    }

    fn shield(self: EnemyType) f32 {
        return switch (self) {
            .shielded => 50.0,
            .boss => 100.0,
            else => 0.0,
        };
    }

    fn getColor(self: EnemyType) rl.Color {
        return switch (self) {
            .normal => rl.Color.red,
            .fast => rl.Color.orange,
            .tank => rl.Color.dark_gray,
            .flying => rl.Color.sky_blue,
            .shielded => rl.Color{ .r = 128, .g = 0, .b = 204, .a = 255 },
            .healer => rl.Color{ .r = 51, .g = 204, .b = 77, .a = 255 },
            .boss => rl.Color{ .r = 153, .g = 0, .b = 153, .a = 255 },
        };
    }

    fn size(self: EnemyType) f32 {
        return switch (self) {
            .normal => 15.0,
            .fast => 12.0,
            .tank => 20.0,
            .flying => 15.0,
            .shielded => 18.0,
            .healer => 16.0,
            .boss => 30.0,
        };
    }
};

const EffectType = enum {
    explosion,
    poison_bubble,
    death_particle,
};

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

const Tower = struct {
    tower_type: TowerType,
    level: u32,
    cooldown: f32,
    target: ?ecs.Entity,
    fire_animation: f32,
    tracking_time: f32,
};

const Enemy = struct {
    health: f32,
    max_health: f32,
    shield_health: f32,
    max_shield: f32,
    speed: f32,
    path_index: usize,
    path_progress: f32,
    value: u32,
    enemy_type: EnemyType,
    slow_duration: f32,
    poison_duration: f32,
    poison_damage: f32,
    is_flying: bool,
};

const Projectile = struct {
    damage: f32,
    target: ecs.Entity,
    speed: f32,
    tower_type: TowerType,
    start_x: f32,
    start_y: f32,
    arc_height: f32,
    flight_progress: f32,
};

const GridCell = struct {
    x: i32,
    y: i32,
    occupied: bool,
    is_path: bool,
};

const GridPosition = struct {
    x: i32,
    y: i32,
};

const VisualEffect = struct {
    effect_type: EffectType,
    lifetime: f32,
    age: f32,
    vx: f32,
    vy: f32,
};

const MoneyPopup = struct {
    lifetime: f32,
    amount: i32,
};

const BasicEnemy = struct {};
const TankEnemy = struct {};
const FastEnemy = struct {};
const FlyingEnemy = struct {};
const HealerEnemy = struct {};
const BasicTower = struct {};
const FrostTower = struct {};
const CannonTower = struct {};
const SniperTower = struct {};
const PoisonTower = struct {};
const PathCell = struct {};

const EnemySpawnedEvent = struct {
    entity: ecs.Entity,
    enemy_type: EnemyType,
};

const EnemyDiedEvent = struct {
    entity: ecs.Entity,
    pos_x: f32,
    pos_y: f32,
    reward: u32,
    enemy_type: EnemyType,
};

const EnemyReachedEndEvent = struct {
    entity: ecs.Entity,
    damage: u32,
};

const ProjectileHitEvent = struct {
    projectile: ecs.Entity,
    target: ecs.Entity,
    pos_x: f32,
    pos_y: f32,
    damage: f32,
    tower_type: TowerType,
};

const TowerPlacedEvent = struct {
    entity: ecs.Entity,
    tower_type: TowerType,
    grid_x: i32,
    grid_y: i32,
    tower_cost: u32,
};

const TowerSoldEvent = struct {
    entity: ecs.Entity,
    tower_type: TowerType,
    grid_x: i32,
    grid_y: i32,
    refund: u32,
};

const TowerUpgradedEvent = struct {
    entity: ecs.Entity,
    tower_type: TowerType,
    old_level: u32,
    new_level: u32,
    upgrade_cost: u32,
};

const WaveCompletedEvent = struct {
    wave: u32,
};

const WaveStartedEvent = struct {
    wave: u32,
    enemy_count: usize,
};

const EnemySpawnInfo = struct {
    enemy_type: EnemyType,
    spawn_time: f32,
};

const GameResources = struct {
    money: u32,
    lives: u32,
    wave: u32,
    game_state: GameState,
    selected_tower_type: TowerType,
    spawn_timer: f32,
    enemies_to_spawn: std.ArrayListUnmanaged(EnemySpawnInfo),
    mouse_grid_x: ?i32,
    mouse_grid_y: ?i32,
    path: std.ArrayListUnmanaged([2]f32),
    wave_announce_timer: f32,
    game_speed: f32,
    current_hp: u32,
    max_hp: u32,
};

const World = ecs.WorldConfig(.{
    .components = .{
        Position,
        Velocity,
        Tower,
        Enemy,
        Projectile,
        GridCell,
        GridPosition,
        VisualEffect,
        MoneyPopup,
        BasicEnemy,
        TankEnemy,
        FastEnemy,
        FlyingEnemy,
        HealerEnemy,
        BasicTower,
        FrostTower,
        CannonTower,
        SniperTower,
        PoisonTower,
        PathCell,
    },
    .Resources = GameResources,
    .events = .{
        .enemy_spawned = EnemySpawnedEvent,
        .enemy_died = EnemyDiedEvent,
        .enemy_reached_end = EnemyReachedEndEvent,
        .projectile_hit = ProjectileHitEvent,
        .tower_placed = TowerPlacedEvent,
        .tower_sold = TowerSoldEvent,
        .tower_upgraded = TowerUpgradedEvent,
        .wave_completed = WaveCompletedEvent,
        .wave_started = WaveStartedEvent,
    },
});

const POSITION = World.getBit(Position);
const VELOCITY = World.getBit(Velocity);
const TOWER = World.getBit(Tower);
const ENEMY = World.getBit(Enemy);
const PROJECTILE = World.getBit(Projectile);
const GRID_CELL = World.getBit(GridCell);
const GRID_POSITION = World.getBit(GridPosition);
const VISUAL_EFFECT = World.getBit(VisualEffect);
const MONEY_POPUP = World.getBit(MoneyPopup);
const BASIC_ENEMY = World.getBit(BasicEnemy);
const TANK_ENEMY = World.getBit(TankEnemy);
const FAST_ENEMY = World.getBit(FastEnemy);
const FLYING_ENEMY = World.getBit(FlyingEnemy);
const HEALER_ENEMY = World.getBit(HealerEnemy);
const BASIC_TOWER = World.getBit(BasicTower);
const FROST_TOWER = World.getBit(FrostTower);
const CANNON_TOWER = World.getBit(CannonTower);
const SNIPER_TOWER = World.getBit(SniperTower);
const POISON_TOWER = World.getBit(PoisonTower);
const PATH_CELL = World.getBit(PathCell);

const GRID_SIZE: i32 = 12;
const TILE_SIZE: f32 = 40.0;
const BASE_WIDTH: f32 = 1024.0;
const BASE_HEIGHT: f32 = 768.0;

var prng: std.Random.DefaultPrng = undefined;

fn randomFloat() f32 {
    return prng.random().float(f32);
}

fn randomRange(min_val: f32, max_val: f32) f32 {
    return min_val + (max_val - min_val) * randomFloat();
}

fn getScale() f32 {
    const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
    return @min(screen_w / BASE_WIDTH, screen_h / BASE_HEIGHT);
}

fn getOffset() [2]f32 {
    const scale = getScale();
    const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
    const scaled_width = BASE_WIDTH * scale;
    const scaled_height = BASE_HEIGHT * scale;
    return .{
        (screen_w - scaled_width) / 2.0,
        (screen_h - scaled_height) / 2.0,
    };
}

fn gridToBase(grid_x: i32, grid_y: i32) [2]f32 {
    const num_cells: f32 = @floatFromInt(GRID_SIZE + 1);
    const grid_width = num_cells * TILE_SIZE;
    const grid_height = num_cells * TILE_SIZE;
    const grid_offset_x = (BASE_WIDTH - grid_width) / 2.0;
    const grid_offset_y = (BASE_HEIGHT - grid_height) / 2.0;

    const tile_x: f32 = @floatFromInt(grid_x + @divTrunc(GRID_SIZE, 2));
    const tile_y: f32 = @floatFromInt(grid_y + @divTrunc(GRID_SIZE, 2));

    return .{
        grid_offset_x + (tile_x + 0.5) * TILE_SIZE,
        grid_offset_y + (tile_y + 0.5) * TILE_SIZE,
    };
}

fn gridToScreen(grid_x: i32, grid_y: i32) [2]f32 {
    const base_pos = gridToBase(grid_x, grid_y);
    const scale = getScale();
    const offset = getOffset();
    return .{
        offset[0] + base_pos[0] * scale,
        offset[1] + base_pos[1] * scale,
    };
}

fn screenToGrid(screen_x: f32, screen_y: f32) ?[2]i32 {
    const scale = getScale();
    const offset = getOffset();

    const num_cells: f32 = @floatFromInt(GRID_SIZE + 1);
    const grid_width = num_cells * TILE_SIZE;
    const grid_height = num_cells * TILE_SIZE;
    const grid_offset_x = (BASE_WIDTH - grid_width) / 2.0;
    const grid_offset_y = (BASE_HEIGHT - grid_height) / 2.0;

    const local_x = (screen_x - offset[0]) / scale;
    const local_y = (screen_y - offset[1]) / scale;

    const rel_x = local_x - grid_offset_x;
    const rel_y = local_y - grid_offset_y;

    if (rel_x < 0 or rel_y < 0 or rel_x >= grid_width or rel_y >= grid_height) {
        return null;
    }

    const tile_x: i32 = @intFromFloat(@floor(rel_x / TILE_SIZE));
    const tile_y: i32 = @intFromFloat(@floor(rel_y / TILE_SIZE));

    return .{
        tile_x - @divTrunc(GRID_SIZE, 2),
        tile_y - @divTrunc(GRID_SIZE, 2),
    };
}

fn initializeGrid(world: *World) !void {
    var x: i32 = -@divTrunc(GRID_SIZE, 2);
    while (x <= @divTrunc(GRID_SIZE, 2)) : (x += 1) {
        var y: i32 = -@divTrunc(GRID_SIZE, 2);
        while (y <= @divTrunc(GRID_SIZE, 2)) : (y += 1) {
            _ = try world.spawn(.{GridCell{
                .x = x,
                .y = y,
                .occupied = false,
                .is_path = false,
            }});
        }
    }
}

fn createPath(world: *World) !void {
    const path_points = [_][2]f32{
        .{ -6.0, 0.0 },
        .{ -3.0, 0.0 },
        .{ -3.0, -4.0 },
        .{ 3.0, -4.0 },
        .{ 3.0, 2.0 },
        .{ -1.0, 2.0 },
        .{ -1.0, 5.0 },
        .{ 6.0, 5.0 },
    };

    const num_cells: f32 = @floatFromInt(GRID_SIZE + 1);
    const grid_width = num_cells * TILE_SIZE;
    const grid_height = num_cells * TILE_SIZE;
    const grid_offset_x = (BASE_WIDTH - grid_width) / 2.0;
    const grid_offset_y = (BASE_HEIGHT - grid_height) / 2.0;

    world.resources.path.clearRetainingCapacity();
    for (path_points) |p| {
        const screen_x = grid_offset_x + (p[0] + @as(f32, @floatFromInt(@divTrunc(GRID_SIZE, 2))) + 0.5) * TILE_SIZE;
        const screen_y = grid_offset_y + (p[1] + @as(f32, @floatFromInt(@divTrunc(GRID_SIZE, 2))) + 0.5) * TILE_SIZE;
        try world.resources.path.append(world.allocator, .{ screen_x, screen_y });
    }

    var cells_to_mark: std.ArrayListUnmanaged([2]i32) = .{};
    defer cells_to_mark.deinit(world.allocator);

    for (0..path_points.len - 1) |index| {
        const start = path_points[index];
        const end = path_points[index + 1];
        const steps: usize = 20;

        for (0..steps + 1) |step| {
            const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
            const pos_x = start[0] + (end[0] - start[0]) * t;
            const pos_y = start[1] + (end[1] - start[1]) * t;
            const grid_x: i32 = @intFromFloat(@round(pos_x));
            const grid_y: i32 = @intFromFloat(@round(pos_y));
            try cells_to_mark.append(world.allocator, .{ grid_x, grid_y });
        }
    }

    const EntityMark = struct { entity: ecs.Entity, x: i32, y: i32 };
    var entities_to_mark: std.ArrayListUnmanaged(EntityMark) = .{};
    defer entities_to_mark.deinit(world.allocator);

    const matching = try world.getMatchingArchetypes(GRID_CELL, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const cells = World.columnWithBit(arch, GridCell, GRID_CELL);
        const entities = arch.entities.items;

        for (cells, entities) |cell, entity| {
            for (cells_to_mark.items) |mark| {
                if (cell.x == mark[0] and cell.y == mark[1]) {
                    try entities_to_mark.append(world.allocator, .{ .entity = entity, .x = cell.x, .y = cell.y });
                    break;
                }
            }
        }
    }

    for (entities_to_mark.items) |em| {
        if (world.get(em.entity, GridCell)) |cell| {
            cell.is_path = true;
            cell.occupied = true;
        }
        _ = try world.addComponent(em.entity, PathCell{});
    }
}

fn spawnTower(world: *World, grid_x: i32, grid_y: i32, tower_type: TowerType) !ecs.Entity {
    const position = gridToBase(grid_x, grid_y);

    const entity = try world.spawn(.{
        Position{ .x = position[0], .y = position[1] },
        GridPosition{ .x = grid_x, .y = grid_y },
        Tower{
            .tower_type = tower_type,
            .level = 1,
            .cooldown = 0,
            .target = null,
            .fire_animation = 0,
            .tracking_time = 0,
        },
    });

    switch (tower_type) {
        .basic => _ = try world.addComponent(entity, BasicTower{}),
        .frost => _ = try world.addComponent(entity, FrostTower{}),
        .cannon => _ = try world.addComponent(entity, CannonTower{}),
        .sniper => _ = try world.addComponent(entity, SniperTower{}),
        .poison => _ = try world.addComponent(entity, PoisonTower{}),
    }

    const tower_cost = tower_type.cost();
    world.resources.money -= tower_cost;

    try world.send("tower_placed", TowerPlacedEvent{
        .entity = entity,
        .tower_type = tower_type,
        .grid_x = grid_x,
        .grid_y = grid_y,
        .tower_cost = tower_cost,
    });

    return entity;
}

fn spawnEnemy(world: *World, enemy_type: EnemyType) !ecs.Entity {
    const start_pos = world.resources.path.items[0];
    const hp = enemy_type.health(world.resources.wave);
    const shield_hp = enemy_type.shield();

    const entity = try world.spawn(.{
        Position{ .x = start_pos[0], .y = start_pos[1] },
        Velocity{ .x = 0, .y = 0 },
        Enemy{
            .health = hp,
            .max_health = hp,
            .shield_health = shield_hp,
            .max_shield = shield_hp,
            .speed = enemy_type.speed(),
            .path_index = 0,
            .path_progress = 0,
            .value = enemy_type.value(world.resources.wave),
            .enemy_type = enemy_type,
            .slow_duration = 0,
            .poison_duration = 0,
            .poison_damage = 0,
            .is_flying = enemy_type == .flying,
        },
    });

    switch (enemy_type) {
        .normal => _ = try world.addComponent(entity, BasicEnemy{}),
        .tank => _ = try world.addComponent(entity, TankEnemy{}),
        .fast => _ = try world.addComponent(entity, FastEnemy{}),
        .flying => _ = try world.addComponent(entity, FlyingEnemy{}),
        .healer => _ = try world.addComponent(entity, HealerEnemy{}),
        else => _ = try world.addComponent(entity, BasicEnemy{}),
    }

    try world.send("enemy_spawned", EnemySpawnedEvent{ .entity = entity, .enemy_type = enemy_type });

    return entity;
}

fn spawnProjectile(world: *World, from_x: f32, from_y: f32, target: ecs.Entity, tower_type: TowerType, level: u32) !ecs.Entity {
    const arc_height: f32 = if (tower_type == .cannon) 50.0 else 0.0;

    return try world.spawn(.{
        Position{ .x = from_x, .y = from_y },
        Velocity{ .x = 0, .y = 0 },
        Projectile{
            .damage = tower_type.damage(level),
            .target = target,
            .speed = tower_type.projectileSpeed(),
            .tower_type = tower_type,
            .start_x = from_x,
            .start_y = from_y,
            .arc_height = arc_height,
            .flight_progress = 0,
        },
    });
}

fn spawnVisualEffect(world: *World, pos_x: f32, pos_y: f32, effect_type: EffectType, vx: f32, vy: f32, lifetime: f32) !void {
    _ = try world.spawn(.{
        Position{ .x = pos_x, .y = pos_y },
        VisualEffect{
            .effect_type = effect_type,
            .lifetime = lifetime,
            .age = 0,
            .vx = vx,
            .vy = vy,
        },
    });
}

fn spawnMoneyPopup(world: *World, pos_x: f32, pos_y: f32, amount: i32) !void {
    _ = try world.spawn(.{
        Position{ .x = pos_x, .y = pos_y },
        MoneyPopup{ .lifetime = 0, .amount = amount },
    });
}

fn canPlaceTowerAt(world: *World, x: i32, y: i32) !bool {
    const tower_matching = try world.getMatchingArchetypes(TOWER | GRID_POSITION, 0);
    for (tower_matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const grid_positions = World.columnWithBit(arch, GridPosition, GRID_POSITION);
        for (grid_positions) |gp| {
            if (gp.x == x and gp.y == y) {
                return false;
            }
        }
    }

    const cell_matching = try world.getMatchingArchetypes(GRID_CELL, 0);
    for (cell_matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const cells = World.columnWithBit(arch, GridCell, GRID_CELL);
        for (cells) |cell| {
            if (cell.x == x and cell.y == y and !cell.occupied) {
                return true;
            }
        }
    }
    return false;
}

fn markCellOccupied(world: *World, x: i32, y: i32) !void {
    const matching = try world.getMatchingArchetypes(GRID_CELL, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const cells = World.columnWithBit(arch, GridCell, GRID_CELL);
        for (cells) |*cell| {
            if (cell.x == x and cell.y == y) {
                cell.occupied = true;
                return;
            }
        }
    }
}

fn planWave(world: *World) !void {
    world.resources.wave += 1;
    const wave = world.resources.wave;

    const WeightedEnemy = struct { enemy_type: EnemyType, weight: f32 };

    const enemy_types: []const WeightedEnemy = switch (wave) {
        1, 2 => &[_]WeightedEnemy{.{ .enemy_type = .normal, .weight = 1.0 }},
        3, 4 => &[_]WeightedEnemy{
            .{ .enemy_type = .normal, .weight = 0.7 },
            .{ .enemy_type = .fast, .weight = 0.3 },
        },
        5, 6 => &[_]WeightedEnemy{
            .{ .enemy_type = .normal, .weight = 0.5 },
            .{ .enemy_type = .fast, .weight = 0.3 },
            .{ .enemy_type = .tank, .weight = 0.2 },
        },
        7, 8 => &[_]WeightedEnemy{
            .{ .enemy_type = .normal, .weight = 0.3 },
            .{ .enemy_type = .fast, .weight = 0.3 },
            .{ .enemy_type = .tank, .weight = 0.2 },
            .{ .enemy_type = .flying, .weight = 0.2 },
        },
        9, 10 => &[_]WeightedEnemy{
            .{ .enemy_type = .normal, .weight = 0.2 },
            .{ .enemy_type = .fast, .weight = 0.2 },
            .{ .enemy_type = .tank, .weight = 0.2 },
            .{ .enemy_type = .flying, .weight = 0.2 },
            .{ .enemy_type = .shielded, .weight = 0.2 },
        },
        11, 12 => &[_]WeightedEnemy{
            .{ .enemy_type = .fast, .weight = 0.2 },
            .{ .enemy_type = .tank, .weight = 0.2 },
            .{ .enemy_type = .flying, .weight = 0.2 },
            .{ .enemy_type = .shielded, .weight = 0.2 },
            .{ .enemy_type = .healer, .weight = 0.2 },
        },
        13, 14 => &[_]WeightedEnemy{
            .{ .enemy_type = .tank, .weight = 0.2 },
            .{ .enemy_type = .flying, .weight = 0.2 },
            .{ .enemy_type = .shielded, .weight = 0.2 },
            .{ .enemy_type = .healer, .weight = 0.2 },
            .{ .enemy_type = .boss, .weight = 0.2 },
        },
        else => &[_]WeightedEnemy{
            .{ .enemy_type = .tank, .weight = 0.15 },
            .{ .enemy_type = .flying, .weight = 0.2 },
            .{ .enemy_type = .shielded, .weight = 0.2 },
            .{ .enemy_type = .healer, .weight = 0.2 },
            .{ .enemy_type = .boss, .weight = 0.25 },
        },
    };

    const spawn_interval: f32 = switch (wave) {
        1, 2, 3 => 1.0,
        4, 5, 6 => 0.8,
        7, 8, 9 => 0.6,
        else => 0.5,
    };

    const enemy_count = 5 + wave * 2;
    var spawn_time: f32 = 0;

    world.resources.enemies_to_spawn.clearRetainingCapacity();

    for (0..enemy_count) |_| {
        const roll = randomFloat();
        var cumulative: f32 = 0;
        var selected_type: EnemyType = .normal;

        for (enemy_types) |weighted| {
            cumulative += weighted.weight;
            if (roll < cumulative) {
                selected_type = weighted.enemy_type;
                break;
            }
        }

        try world.resources.enemies_to_spawn.append(world.allocator, EnemySpawnInfo{
            .enemy_type = selected_type,
            .spawn_time = spawn_time,
        });
        spawn_time += spawn_interval;
    }

    world.resources.spawn_timer = 0;
    world.resources.game_state = .wave_in_progress;
    world.resources.wave_announce_timer = 3.0;

    try world.send("wave_started", WaveStartedEvent{
        .wave = wave,
        .enemy_count = enemy_count,
    });
}

fn waveSpawningSystem(world: *World, delta_time: f32) !void {
    if (world.resources.game_state != .wave_in_progress) return;

    world.resources.spawn_timer += delta_time;
    const current_time = world.resources.spawn_timer;

    var spawns_to_process: std.ArrayListUnmanaged(EnemyType) = .{};
    defer spawns_to_process.deinit(world.allocator);

    var indices_to_remove: std.ArrayListUnmanaged(usize) = .{};
    defer indices_to_remove.deinit(world.allocator);

    for (world.resources.enemies_to_spawn.items, 0..) |spawn_info, index| {
        if (spawn_info.spawn_time <= current_time) {
            try spawns_to_process.append(world.allocator, spawn_info.enemy_type);
            try indices_to_remove.append(world.allocator, index);
        }
    }

    for (spawns_to_process.items) |enemy_type| {
        _ = try spawnEnemy(world, enemy_type);
    }

    var removed: usize = 0;
    for (indices_to_remove.items) |index| {
        _ = world.resources.enemies_to_spawn.orderedRemove(index - removed);
        removed += 1;
    }

    const enemy_count = try world.queryCount(ENEMY, 0);

    if (world.resources.enemies_to_spawn.items.len == 0 and enemy_count == 0) {
        try world.send("wave_completed", WaveCompletedEvent{ .wave = world.resources.wave });

        if (world.resources.wave >= 20) {
            world.resources.game_state = .victory;
        } else {
            try planWave(world);
        }
    }
}

fn enemyMovementSystem(world: *World, delta_time: f32) !void {
    const path = world.resources.path.items;
    if (path.len < 2) return;

    var hp_damage: u32 = 0;

    const matching = try world.getMatchingArchetypes(ENEMY | POSITION, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const positions = World.columnWithBit(arch, Position, POSITION);
        const enemies = World.columnWithBit(arch, Enemy, ENEMY);
        const entities = arch.entities.items;

        for (positions, enemies, entities) |*pos, *enemy, entity| {
            if (enemy.health <= 0) continue;

            const speed_multiplier: f32 = if (enemy.slow_duration > 0) 0.5 else 1.0;
            const spd = enemy.speed * speed_multiplier;

            enemy.path_progress += spd * delta_time;

            if (enemy.slow_duration > 0) {
                enemy.slow_duration -= delta_time;
            }

            if (enemy.poison_duration > 0) {
                enemy.poison_duration -= delta_time;
                enemy.health -= enemy.poison_damage * delta_time;
                if (enemy.health <= 0) {
                    try world.queueDespawn(entity);
                    world.resources.money += enemy.value;
                    try world.send("enemy_died", EnemyDiedEvent{
                        .entity = entity,
                        .pos_x = pos.x,
                        .pos_y = pos.y,
                        .reward = enemy.value,
                        .enemy_type = enemy.enemy_type,
                    });
                    continue;
                }
            }

            if (enemy.path_index < path.len - 1) {
                const current = path[enemy.path_index];
                const next = path[enemy.path_index + 1];
                const dx = next[0] - current[0];
                const dy = next[1] - current[1];
                const segment_length = @sqrt(dx * dx + dy * dy);

                if (enemy.path_progress >= segment_length) {
                    enemy.path_progress -= segment_length;
                    enemy.path_index += 1;

                    if (enemy.path_index >= path.len - 1) {
                        try world.queueDespawn(entity);
                        hp_damage += 1;
                        try world.send("enemy_reached_end", EnemyReachedEndEvent{ .entity = entity, .damage = 1 });
                        continue;
                    }
                }

                const cur = path[enemy.path_index];
                const nxt = path[enemy.path_index + 1];
                const dir_x = nxt[0] - cur[0];
                const dir_y = nxt[1] - cur[1];
                const len = @sqrt(dir_x * dir_x + dir_y * dir_y);
                if (len > 0) {
                    pos.x = cur[0] + (dir_x / len) * enemy.path_progress;
                    pos.y = cur[1] + (dir_y / len) * enemy.path_progress;
                }
            }
        }
    }

    if (hp_damage > 0) {
        if (world.resources.current_hp >= hp_damage) {
            world.resources.current_hp -= hp_damage;
        } else {
            world.resources.current_hp = 0;
        }

        if (world.resources.current_hp == 0) {
            world.resources.current_hp = world.resources.max_hp;
            world.resources.lives -|= 1;

            if (world.resources.lives == 0) {
                world.resources.game_state = .game_over;
            }
        }
    }

    world.applyDespawns();
}

fn towerTargetingSystem(world: *World) !void {
    const EnemyData = struct { entity: ecs.Entity, x: f32, y: f32 };
    var enemy_data: std.ArrayListUnmanaged(EnemyData) = .{};
    defer enemy_data.deinit(world.allocator);

    const enemy_matching = try world.getMatchingArchetypes(ENEMY | POSITION, 0);
    for (enemy_matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const positions = World.columnWithBit(arch, Position, POSITION);
        const entities = arch.entities.items;

        for (positions, entities) |pos, entity| {
            try enemy_data.append(world.allocator, .{ .entity = entity, .x = pos.x, .y = pos.y });
        }
    }

    const tower_matching = try world.getMatchingArchetypes(TOWER | POSITION, 0);
    for (tower_matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const towers = World.columnWithBit(arch, Tower, TOWER);
        const positions = World.columnWithBit(arch, Position, POSITION);

        for (towers, positions) |*tower, pos| {
            const tower_range = tower.tower_type.range(tower.level);
            const range_sq = tower_range * tower_range;

            var closest_enemy: ?ecs.Entity = null;
            var closest_dist_sq: f32 = std.math.floatMax(f32);

            for (enemy_data.items) |ed| {
                const dx = ed.x - pos.x;
                const dy = ed.y - pos.y;
                const dist_sq = dx * dx + dy * dy;
                if (dist_sq <= range_sq and dist_sq < closest_dist_sq) {
                    closest_dist_sq = dist_sq;
                    closest_enemy = ed.entity;
                }
            }

            tower.target = closest_enemy;
            if (tower.target != null) {
                tower.tracking_time += rl.getFrameTime();
            } else {
                tower.tracking_time = 0;
            }
        }
    }
}

fn towerShootingSystem(world: *World, delta_time: f32) !void {
    const ProjectileSpawn = struct { x: f32, y: f32, target: ecs.Entity, tower_type: TowerType, level: u32 };
    var projectiles_to_spawn: std.ArrayListUnmanaged(ProjectileSpawn) = .{};
    defer projectiles_to_spawn.deinit(world.allocator);

    const matching = try world.getMatchingArchetypes(TOWER | POSITION, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const towers = World.columnWithBit(arch, Tower, TOWER);
        const positions = World.columnWithBit(arch, Position, POSITION);

        for (towers, positions) |*tower, pos| {
            tower.cooldown -= delta_time;

            if (tower.fire_animation > 0) {
                tower.fire_animation -= delta_time * 3.0;
            }

            if (tower.cooldown <= 0 and tower.target != null) {
                const can_fire = if (tower.tower_type == .sniper) tower.tracking_time >= 2.0 else true;

                if (can_fire) {
                    try projectiles_to_spawn.append(world.allocator, .{
                        .x = pos.x,
                        .y = pos.y,
                        .target = tower.target.?,
                        .tower_type = tower.tower_type,
                        .level = tower.level,
                    });
                    tower.cooldown = tower.tower_type.fireRate(tower.level);
                    tower.fire_animation = 1.0;
                    tower.tracking_time = 0;
                }
            }
        }
    }

    for (projectiles_to_spawn.items) |spawn| {
        _ = try spawnProjectile(world, spawn.x, spawn.y, spawn.target, spawn.tower_type, spawn.level);

        if (spawn.tower_type == .cannon) {
            for (0..6) |_| {
                const offset_x = randomRange(-5, 5);
                const offset_y = randomRange(-5, 5);
                try spawnVisualEffect(world, spawn.x + offset_x, spawn.y + offset_y, .explosion, 0, 0, 0.3);
            }
        }
    }
}

fn projectileMovementSystem(world: *World, delta_time: f32) !void {
    const EnemyPos = struct { entity: ecs.Entity, x: f32, y: f32 };
    var enemy_positions = std.AutoHashMap(u64, EnemyPos).init(world.allocator);
    defer enemy_positions.deinit();

    const enemy_matching = try world.getMatchingArchetypes(ENEMY | POSITION, 0);
    for (enemy_matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const positions = World.columnWithBit(arch, Position, POSITION);
        const entities = arch.entities.items;

        for (positions, entities) |pos, entity| {
            const key: u64 = @as(u64, entity.id) | (@as(u64, entity.generation) << 32);
            try enemy_positions.put(key, .{ .entity = entity, .x = pos.x, .y = pos.y });
        }
    }

    const Hit = struct { enemy: ecs.Entity, damage: f32, tower_type: TowerType, x: f32, y: f32 };
    var hits: std.ArrayListUnmanaged(Hit) = .{};
    defer hits.deinit(world.allocator);

    const proj_matching = try world.getMatchingArchetypes(PROJECTILE | POSITION, 0);
    for (proj_matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const projectiles = World.columnWithBit(arch, Projectile, PROJECTILE);
        const positions = World.columnWithBit(arch, Position, POSITION);
        const entities = arch.entities.items;

        for (projectiles, positions, entities) |*proj, *pos, entity| {
            const target_key: u64 = @as(u64, proj.target.id) | (@as(u64, proj.target.generation) << 32);

            if (enemy_positions.get(target_key)) |target_pos| {
                const dx = target_pos.x - proj.start_x;
                const dy = target_pos.y - proj.start_y;
                const total_distance = @sqrt(dx * dx + dy * dy);

                const to_target_x = target_pos.x - pos.x;
                const to_target_y = target_pos.y - pos.y;
                const distance_to_target = @sqrt(to_target_x * to_target_x + to_target_y * to_target_y);

                if (proj.arc_height > 0) {
                    proj.flight_progress += (proj.speed * delta_time) / @max(total_distance, 1.0);
                    proj.flight_progress = @min(proj.flight_progress, 1.0);
                    pos.x = proj.start_x + dx * proj.flight_progress;
                    pos.y = proj.start_y + dy * proj.flight_progress;
                } else {
                    if (distance_to_target > 0) {
                        const dir_x = to_target_x / distance_to_target;
                        const dir_y = to_target_y / distance_to_target;
                        pos.x += dir_x * proj.speed * delta_time;
                        pos.y += dir_y * proj.speed * delta_time;
                    }
                }

                if (distance_to_target < 10.0 or proj.flight_progress >= 1.0) {
                    try hits.append(world.allocator, .{
                        .enemy = proj.target,
                        .damage = proj.damage,
                        .tower_type = proj.tower_type,
                        .x = target_pos.x,
                        .y = target_pos.y,
                    });
                    try world.queueDespawn(entity);
                    try world.send("projectile_hit", ProjectileHitEvent{
                        .projectile = entity,
                        .target = proj.target,
                        .pos_x = target_pos.x,
                        .pos_y = target_pos.y,
                        .damage = proj.damage,
                        .tower_type = proj.tower_type,
                    });
                }
            } else {
                try world.queueDespawn(entity);
            }
        }
    }

    for (hits.items) |hit| {
        switch (hit.tower_type) {
            .frost => {
                if (world.get(hit.enemy, Enemy)) |enemy| {
                    enemy.slow_duration = 2.0;
                }
                try applyDamageToEnemy(world, hit.enemy, hit.damage, hit.x, hit.y);
            },
            .poison => {
                if (world.get(hit.enemy, Enemy)) |enemy| {
                    enemy.poison_duration = 3.0;
                    enemy.poison_damage = 5.0;
                }
                try applyDamageToEnemy(world, hit.enemy, hit.damage, hit.x, hit.y);
                for (0..3) |_| {
                    const vx = randomRange(-20, 20);
                    const vy = randomRange(-20, 20);
                    try spawnVisualEffect(world, hit.x, hit.y, .poison_bubble, vx, vy, 2.0);
                }
            },
            .cannon => {
                for (0..8) |_| {
                    const vx = randomRange(-30, 30);
                    const vy = randomRange(-30, 30);
                    try spawnVisualEffect(world, hit.x, hit.y, .explosion, vx, vy, 0.5);
                }

                const aoe_matching = try world.getMatchingArchetypes(ENEMY | POSITION, 0);
                for (aoe_matching) |arch_idx| {
                    const arch = &world.archetypes.items[arch_idx];
                    const positions = World.columnWithBit(arch, Position, POSITION);
                    const entities = arch.entities.items;

                    for (positions, entities) |pos, entity| {
                        const dx = pos.x - hit.x;
                        const dy = pos.y - hit.y;
                        const distance = @sqrt(dx * dx + dy * dy);
                        if (distance < 60.0) {
                            const damage_falloff = 1.0 - (distance / 60.0);
                            try applyDamageToEnemy(world, entity, hit.damage * damage_falloff, pos.x, pos.y);
                        }
                    }
                }
            },
            else => {
                try applyDamageToEnemy(world, hit.enemy, hit.damage, hit.x, hit.y);
            },
        }
    }

    world.applyDespawns();
}

fn applyDamageToEnemy(world: *World, enemy_entity: ecs.Entity, damage: f32, pos_x: f32, pos_y: f32) !void {
    if (world.get(enemy_entity, Enemy)) |enemy| {
        const was_alive = enemy.health > 0;

        if (enemy.shield_health > 0) {
            const shield_damage = @min(damage, enemy.shield_health);
            enemy.shield_health -= shield_damage;
            const remaining = damage - shield_damage;
            if (remaining > 0) {
                enemy.health -= remaining;
            }
        } else {
            enemy.health -= damage;
        }

        if (was_alive and enemy.health <= 0) {
            try world.send("enemy_died", EnemyDiedEvent{
                .entity = enemy_entity,
                .pos_x = pos_x,
                .pos_y = pos_y,
                .reward = enemy.value,
                .enemy_type = enemy.enemy_type,
            });
            try world.queueDespawn(enemy_entity);
        }
    }
}

fn visualEffectsSystem(world: *World, delta_time: f32) !void {
    const matching = try world.getMatchingArchetypes(VISUAL_EFFECT | POSITION, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const effects = World.columnWithBit(arch, VisualEffect, VISUAL_EFFECT);
        const positions = World.columnWithBit(arch, Position, POSITION);
        const entities = arch.entities.items;

        for (effects, positions, entities) |*effect, *pos, entity| {
            effect.age += delta_time;

            if (effect.age >= effect.lifetime) {
                try world.queueDespawn(entity);
            } else {
                pos.x += effect.vx * delta_time;
                pos.y += effect.vy * delta_time;
            }
        }
    }

    world.applyDespawns();
}

fn updateMoneyPopups(world: *World, delta_time: f32) !void {
    const matching = try world.getMatchingArchetypes(MONEY_POPUP | POSITION, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const popups = World.columnWithBit(arch, MoneyPopup, MONEY_POPUP);
        const positions = World.columnWithBit(arch, Position, POSITION);
        const entities = arch.entities.items;

        for (popups, positions, entities) |*popup, *pos, entity| {
            popup.lifetime += delta_time;

            if (popup.lifetime > 2.0) {
                try world.queueDespawn(entity);
            } else {
                pos.y -= delta_time * 30.0;
            }
        }
    }

    world.applyDespawns();
}

fn upgradeTower(world: *World, tower_entity: ecs.Entity, grid_x: i32, grid_y: i32) !bool {
    if (world.get(tower_entity, Tower)) |tower| {
        if (tower.level >= 4) return false;

        const upgrade_cost = tower.tower_type.upgradeCost(tower.level);
        if (world.resources.money < upgrade_cost) return false;

        world.resources.money -= upgrade_cost;
        const old_level = tower.level;
        tower.level += 1;

        try world.send("tower_upgraded", TowerUpgradedEvent{
            .entity = tower_entity,
            .tower_type = tower.tower_type,
            .old_level = old_level,
            .new_level = tower.level,
            .upgrade_cost = upgrade_cost,
        });

        const position = gridToBase(grid_x, grid_y);
        try spawnMoneyPopup(world, position[0], position[1], -@as(i32, @intCast(upgrade_cost)));

        return true;
    }
    return false;
}

fn sellTower(world: *World, tower_entity: ecs.Entity, grid_x: i32, grid_y: i32) !void {
    if (world.get(tower_entity, Tower)) |tower| {
        const refund: u32 = @intFromFloat(@as(f32, @floatFromInt(tower.tower_type.cost())) * 0.7);
        world.resources.money += refund;

        const position = gridToBase(grid_x, grid_y);
        try spawnMoneyPopup(world, position[0], position[1], @intCast(refund));

        try world.send("tower_sold", TowerSoldEvent{
            .entity = tower_entity,
            .tower_type = tower.tower_type,
            .grid_x = grid_x,
            .grid_y = grid_y,
            .refund = refund,
        });

        const cell_matching = try world.getMatchingArchetypes(GRID_CELL, 0);
        for (cell_matching) |arch_idx| {
            const arch = &world.archetypes.items[arch_idx];
            const cells = World.columnWithBit(arch, GridCell, GRID_CELL);
            for (cells) |*cell| {
                if (cell.x == grid_x and cell.y == grid_y) {
                    cell.occupied = false;
                }
            }
        }

        try world.queueDespawn(tower_entity);
        world.applyDespawns();
    }
}

fn restartGame(world: *World) !void {
    const masks_to_clear = [_]u64{ TOWER, ENEMY, PROJECTILE, VISUAL_EFFECT, MONEY_POPUP };

    for (masks_to_clear) |mask| {
        const matching = try world.getMatchingArchetypes(mask, 0);
        for (matching) |arch_idx| {
            const arch = &world.archetypes.items[arch_idx];
            for (arch.entities.items) |entity| {
                try world.queueDespawn(entity);
            }
        }
    }

    world.applyDespawns();

    world.resources.money = 200;
    world.resources.lives = 1;
    world.resources.wave = 0;
    world.resources.current_hp = 20;
    world.resources.max_hp = 20;
    world.resources.game_state = .waiting_for_wave;
    world.resources.game_speed = 1.0;
    world.resources.spawn_timer = 0;
    world.resources.enemies_to_spawn.clearRetainingCapacity();
    world.resources.wave_announce_timer = 0;
}

fn inputSystem(world: *World) !void {
    const mouse_pos = rl.getMousePosition();
    if (screenToGrid(mouse_pos.x, mouse_pos.y)) |grid| {
        world.resources.mouse_grid_x = grid[0];
        world.resources.mouse_grid_y = grid[1];
    } else {
        world.resources.mouse_grid_x = null;
        world.resources.mouse_grid_y = null;
    }

    if (rl.isMouseButtonPressed(.left)) {
        if (world.resources.mouse_grid_x) |grid_x| {
            if (world.resources.mouse_grid_y) |grid_y| {
                if (try canPlaceTowerAt(world, grid_x, grid_y)) {
                    const tower_type = world.resources.selected_tower_type;
                    if (world.resources.money >= tower_type.cost()) {
                        _ = try spawnTower(world, grid_x, grid_y, tower_type);
                        try markCellOccupied(world, grid_x, grid_y);
                        const pos = gridToBase(grid_x, grid_y);
                        try spawnMoneyPopup(world, pos[0], pos[1], -@as(i32, @intCast(tower_type.cost())));
                    }
                }
            }
        }
    }

    if (rl.isMouseButtonPressed(.right)) {
        if (world.resources.mouse_grid_x) |grid_x| {
            if (world.resources.mouse_grid_y) |grid_y| {
                const tower_matching = try world.getMatchingArchetypes(TOWER | GRID_POSITION, 0);
                var tower_to_sell: ?ecs.Entity = null;

                outer: for (tower_matching) |arch_idx| {
                    const arch = &world.archetypes.items[arch_idx];
                    const grid_positions = World.columnWithBit(arch, GridPosition, GRID_POSITION);
                    const entities = arch.entities.items;

                    for (grid_positions, entities) |gp, entity| {
                        if (gp.x == grid_x and gp.y == grid_y) {
                            tower_to_sell = entity;
                            break :outer;
                        }
                    }
                }

                if (tower_to_sell) |entity| {
                    try sellTower(world, entity, grid_x, grid_y);
                }
            }
        }
    }

    if (rl.isMouseButtonPressed(.middle) or rl.isKeyPressed(.u)) {
        if (world.resources.mouse_grid_x) |grid_x| {
            if (world.resources.mouse_grid_y) |grid_y| {
                const tower_matching = try world.getMatchingArchetypes(TOWER | GRID_POSITION, 0);
                var tower_to_upgrade: ?ecs.Entity = null;

                outer: for (tower_matching) |arch_idx| {
                    const arch = &world.archetypes.items[arch_idx];
                    const grid_positions = World.columnWithBit(arch, GridPosition, GRID_POSITION);
                    const entities = arch.entities.items;

                    for (grid_positions, entities) |gp, entity| {
                        if (gp.x == grid_x and gp.y == grid_y) {
                            tower_to_upgrade = entity;
                            break :outer;
                        }
                    }
                }

                if (tower_to_upgrade) |entity| {
                    _ = try upgradeTower(world, entity, grid_x, grid_y);
                }
            }
        }
    }

    if (rl.isKeyPressed(.one)) world.resources.selected_tower_type = .basic;
    if (rl.isKeyPressed(.two)) world.resources.selected_tower_type = .frost;
    if (rl.isKeyPressed(.three)) world.resources.selected_tower_type = .cannon;
    if (rl.isKeyPressed(.four)) world.resources.selected_tower_type = .sniper;
    if (rl.isKeyPressed(.five)) world.resources.selected_tower_type = .poison;

    if (rl.isKeyPressed(.left_bracket)) {
        world.resources.game_speed = @max(world.resources.game_speed - 0.5, 0.5);
    }
    if (rl.isKeyPressed(.right_bracket)) {
        world.resources.game_speed = @min(world.resources.game_speed + 0.5, 3.0);
    }
    if (rl.isKeyPressed(.backslash)) {
        world.resources.game_speed = 1.0;
    }

    if (rl.isKeyPressed(.p)) {
        if (world.resources.game_state == .wave_in_progress) {
            world.resources.game_state = .paused;
        } else if (world.resources.game_state == .paused) {
            world.resources.game_state = .wave_in_progress;
        }
    }

    if (rl.isKeyPressed(.r)) {
        if (world.resources.game_state == .game_over or world.resources.game_state == .victory) {
            try restartGame(world);
        }
    }

    if (rl.isKeyPressed(.space) and world.resources.game_state == .waiting_for_wave) {
        try planWave(world);
    }
}

fn enemyDiedEventHandler(world: *World) !void {
    for (world.eventSlice("enemy_died")) |event| {
        world.resources.money += event.reward;

        for (0..6) |_| {
            const vx = randomRange(-40, 40);
            const vy = randomRange(-40, 40);
            try spawnVisualEffect(world, event.pos_x, event.pos_y, .death_particle, vx, vy, 0.8);
        }

        if (event.reward > 0) {
            try spawnMoneyPopup(world, event.pos_x, event.pos_y, @intCast(event.reward));
        }
    }
    world.clearEvents("enemy_died");
}

fn enemySpawnedEventHandler(world: *World) !void {
    for (world.eventSlice("enemy_spawned")) |event| {
        if (world.get(event.entity, Position)) |pos| {
            for (0..4) |_| {
                const vx = randomRange(-30, 30);
                const vy = randomRange(-30, 30);
                try spawnVisualEffect(world, pos.x, pos.y, .death_particle, vx, vy, 0.5);
            }
        }
    }
    world.clearEvents("enemy_spawned");
}

fn towerPlacedEventHandler(world: *World) !void {
    for (world.eventSlice("tower_placed")) |event| {
        const pos = gridToBase(event.grid_x, event.grid_y);
        for (0..5) |_| {
            const offset_x = randomRange(-15, 15);
            const offset_y = randomRange(-15, 15);
            try spawnVisualEffect(world, pos[0] + offset_x, pos[1] + offset_y, .explosion, 0, 0, 0.4);
        }
    }
    world.clearEvents("tower_placed");
}

fn towerSoldEventHandler(world: *World) !void {
    for (world.eventSlice("tower_sold")) |event| {
        const pos = gridToBase(event.grid_x, event.grid_y);
        for (0..8) |_| {
            const vx = randomRange(-40, 40);
            const vy = randomRange(-40, 40);
            try spawnVisualEffect(world, pos[0], pos[1], .death_particle, vx, vy, 0.7);
        }
    }
    world.clearEvents("tower_sold");
}

fn towerUpgradedEventHandler(world: *World) !void {
    for (world.eventSlice("tower_upgraded")) |event| {
        if (world.get(event.entity, Position)) |pos| {
            for (0..12) |_| {
                const angle = randomFloat() * std.math.pi * 2.0;
                const spd = randomRange(20, 60);
                const vx = @cos(angle) * spd;
                const vy = @sin(angle) * spd;
                try spawnVisualEffect(world, pos.x, pos.y, .explosion, vx, vy, 0.8);
            }
        }
    }
    world.clearEvents("tower_upgraded");
}

fn waveCompletedEventHandler(world: *World) !void {
    for (world.eventSlice("wave_completed")) |event| {
        const bonus = 20 + event.wave * 5;
        world.resources.money += bonus;
    }
    world.clearEvents("wave_completed");
}

fn renderGrid(world: *World) !void {
    const scale = getScale();
    const offset = getOffset();

    const matching = try world.getMatchingArchetypes(GRID_CELL, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const cells = World.columnWithBit(arch, GridCell, GRID_CELL);

        for (cells) |cell| {
            const base_pos = gridToBase(cell.x, cell.y);
            const pos_x = offset[0] + base_pos[0] * scale;
            const pos_y = offset[1] + base_pos[1] * scale;

            const path_start = world.resources.path.items[0];
            const path_end = world.resources.path.items[world.resources.path.items.len - 1];

            const start_screen_x = offset[0] + path_start[0] * scale;
            const start_screen_y = offset[1] + path_start[1] * scale;
            const end_screen_x = offset[0] + path_end[0] * scale;
            const end_screen_y = offset[1] + path_end[1] * scale;

            const to_start_x = pos_x - start_screen_x;
            const to_start_y = pos_y - start_screen_y;
            const to_end_x = pos_x - end_screen_x;
            const to_end_y = pos_y - end_screen_y;

            const is_start = @sqrt(to_start_x * to_start_x + to_start_y * to_start_y) < TILE_SIZE * scale / 2.0;
            const is_end = @sqrt(to_end_x * to_end_x + to_end_y * to_end_y) < TILE_SIZE * scale / 2.0;

            const color = if (is_start)
                rl.Color.orange
            else if (is_end)
                rl.Color.blue
            else if (cell.is_path)
                rl.Color{ .r = 128, .g = 77, .b = 26, .a = 255 }
            else
                rl.Color{ .r = 26, .g = 77, .b = 26, .a = 255 };

            const rect_x: c_int = @intFromFloat(pos_x - TILE_SIZE * scale / 2.0 + scale);
            const rect_y: c_int = @intFromFloat(pos_y - TILE_SIZE * scale / 2.0 + scale);
            const rect_w: c_int = @intFromFloat((TILE_SIZE - 2.0) * scale);
            const rect_h: c_int = @intFromFloat((TILE_SIZE - 2.0) * scale);

            rl.drawRectangle(rect_x, rect_y, rect_w, rect_h, color);
        }
    }

    if (world.resources.mouse_grid_x) |grid_x| {
        if (world.resources.mouse_grid_y) |grid_y| {
            if (try canPlaceTowerAt(world, grid_x, grid_y)) {
                const tower_type = world.resources.selected_tower_type;
                if (world.resources.money >= tower_type.cost()) {
                    const pos = gridToScreen(grid_x, grid_y);
                    const tower_color = tower_type.color();

                    const rect_x: c_int = @intFromFloat(pos[0] - TILE_SIZE * scale / 2.0 + scale);
                    const rect_y: c_int = @intFromFloat(pos[1] - TILE_SIZE * scale / 2.0 + scale);
                    const rect_w: c_int = @intFromFloat((TILE_SIZE - 2.0) * scale);
                    const rect_h: c_int = @intFromFloat((TILE_SIZE - 2.0) * scale);

                    rl.drawRectangle(rect_x, rect_y, rect_w, rect_h, rl.Color{ .r = tower_color.r, .g = tower_color.g, .b = tower_color.b, .a = 77 });

                    rl.drawCircleLines(@intFromFloat(pos[0]), @intFromFloat(pos[1]), tower_type.range(1) * scale, rl.Color{ .r = tower_color.r, .g = tower_color.g, .b = tower_color.b, .a = 128 });
                }
            }
        }
    }
}

fn renderTowers(world: *World) !void {
    const scale = getScale();
    const offset = getOffset();

    const matching = try world.getMatchingArchetypes(TOWER | POSITION, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const towers = World.columnWithBit(arch, Tower, TOWER);
        const positions = World.columnWithBit(arch, Position, POSITION);

        for (towers, positions) |tower, pos| {
            const screen_x = offset[0] + pos.x * scale;
            const screen_y = offset[1] + pos.y * scale;

            const base_size = 20.0 + tower.fire_animation * 4.0;
            const size = base_size * (1.0 + 0.15 * @as(f32, @floatFromInt(tower.level - 1))) * scale;

            const color = tower.tower_type.color();
            const level_brightness = 1.0 + 0.2 * @as(f32, @floatFromInt(tower.level - 1));
            const upgraded_color = rl.Color{
                .r = @intFromFloat(@min(@as(f32, @floatFromInt(color.r)) * level_brightness, 255.0)),
                .g = @intFromFloat(@min(@as(f32, @floatFromInt(color.g)) * level_brightness, 255.0)),
                .b = @intFromFloat(@min(@as(f32, @floatFromInt(color.b)) * level_brightness, 255.0)),
                .a = 255,
            };

            rl.drawCircle(@intFromFloat(screen_x), @intFromFloat(screen_y), size / 2.0, upgraded_color);
            rl.drawCircleLines(@intFromFloat(screen_x), @intFromFloat(screen_y), size / 2.0, rl.Color.black);

            for (1..tower.level) |ring| {
                const ring_radius = size / 2.0 + @as(f32, @floatFromInt(ring)) * 3.0 * scale;
                rl.drawCircleLines(@intFromFloat(screen_x), @intFromFloat(screen_y), ring_radius, upgraded_color);
            }
        }
    }
}

fn renderEnemies(world: *World) !void {
    const scale = getScale();
    const offset = getOffset();

    const matching = try world.getMatchingArchetypes(ENEMY | POSITION, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const enemies = World.columnWithBit(arch, Enemy, ENEMY);
        const positions = World.columnWithBit(arch, Position, POSITION);

        for (enemies, positions) |enemy, pos| {
            const screen_x = offset[0] + pos.x * scale;
            const screen_y = offset[1] + pos.y * scale;
            const size = enemy.enemy_type.size() * scale;

            rl.drawCircle(@intFromFloat(screen_x), @intFromFloat(screen_y), size, enemy.enemy_type.getColor());
            rl.drawCircleLines(@intFromFloat(screen_x), @intFromFloat(screen_y), size, rl.Color.black);

            if (enemy.shield_health > 0) {
                const shield_alpha: u8 = @intFromFloat((enemy.shield_health / enemy.max_shield) * 255.0);
                rl.drawCircleLines(@intFromFloat(screen_x), @intFromFloat(screen_y), size + 3.0 * scale, rl.Color{ .r = 128, .g = 128, .b = 255, .a = shield_alpha });
            }

            const health_percent = enemy.health / enemy.max_health;
            const bar_width = size * 2.0;
            const bar_height = 4.0 * scale;
            const bar_y = screen_y - size - 10.0 * scale;

            rl.drawRectangle(@intFromFloat(screen_x - bar_width / 2.0), @intFromFloat(bar_y), @intFromFloat(bar_width), @intFromFloat(bar_height), rl.Color.black);

            const health_color = if (health_percent > 0.5) rl.Color.green else if (health_percent > 0.25) rl.Color.yellow else rl.Color.red;
            rl.drawRectangle(@intFromFloat(screen_x - bar_width / 2.0), @intFromFloat(bar_y), @intFromFloat(bar_width * health_percent), @intFromFloat(bar_height), health_color);
        }
    }
}

fn renderProjectiles(world: *World) !void {
    const scale = getScale();
    const offset = getOffset();

    const matching = try world.getMatchingArchetypes(PROJECTILE | POSITION, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const projectiles = World.columnWithBit(arch, Projectile, PROJECTILE);
        const positions = World.columnWithBit(arch, Position, POSITION);

        for (projectiles, positions) |proj, pos| {
            const screen_x = offset[0] + pos.x * scale;
            const screen_y = offset[1] + pos.y * scale;

            const color = if (proj.tower_type == .basic)
                rl.Color.yellow
            else if (proj.tower_type == .frost)
                rl.Color.sky_blue
            else if (proj.tower_type == .cannon)
                rl.Color.orange
            else if (proj.tower_type == .sniper)
                rl.Color.light_gray
            else
                rl.Color{ .r = 128, .g = 0, .b = 204, .a = 255 };

            const base_size: f32 = if (proj.tower_type == .cannon) 8.0 else if (proj.tower_type == .sniper) 10.0 else 5.0;
            const size: f32 = base_size * scale;

            rl.drawCircle(@intFromFloat(screen_x), @intFromFloat(screen_y), size, color);
        }
    }
}

fn renderVisualEffects(world: *World) !void {
    const scale = getScale();
    const offset = getOffset();

    const matching = try world.getMatchingArchetypes(VISUAL_EFFECT | POSITION, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const effects = World.columnWithBit(arch, VisualEffect, VISUAL_EFFECT);
        const positions = World.columnWithBit(arch, Position, POSITION);

        for (effects, positions) |effect, pos| {
            const screen_x = offset[0] + pos.x * scale;
            const screen_y = offset[1] + pos.y * scale;
            const progress = effect.age / effect.lifetime;
            const alpha: u8 = @intFromFloat((1.0 - progress) * 255.0);

            switch (effect.effect_type) {
                .explosion => {
                    const size = (1.0 - progress) * 10.0 * scale;
                    rl.drawCircle(@intFromFloat(screen_x), @intFromFloat(screen_y), size, rl.Color{ .r = 255, .g = 128, .b = 0, .a = alpha });
                },
                .poison_bubble => {
                    const size = 5.0 * (1.0 + progress * 0.5) * scale;
                    const bubble_alpha: u8 = @intFromFloat(@as(f32, @floatFromInt(alpha)) * 0.6);
                    rl.drawCircle(@intFromFloat(screen_x), @intFromFloat(screen_y), size, rl.Color{ .r = 128, .g = 0, .b = 204, .a = bubble_alpha });
                },
                .death_particle => {
                    const size = (1.0 - progress) * 5.0 * scale;
                    rl.drawCircle(@intFromFloat(screen_x), @intFromFloat(screen_y), size, rl.Color{ .r = 255, .g = 0, .b = 0, .a = alpha });
                },
            }
        }
    }
}

fn renderMoneyPopups(world: *World) !void {
    const scale = getScale();
    const offset = getOffset();

    const matching = try world.getMatchingArchetypes(MONEY_POPUP | POSITION, 0);
    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];
        const popups = World.columnWithBit(arch, MoneyPopup, MONEY_POPUP);
        const positions = World.columnWithBit(arch, Position, POSITION);

        for (popups, positions) |popup, pos| {
            const screen_x = offset[0] + pos.x * scale;
            const screen_y = offset[1] + pos.y * scale;
            const progress = popup.lifetime / 2.0;
            const alpha: u8 = @intFromFloat((1.0 - @min(progress, 1.0)) * 255.0);

            var buf: [32]u8 = undefined;
            const text = if (popup.amount > 0)
                std.fmt.bufPrintZ(&buf, "+${d}", .{popup.amount}) catch "+$?"
            else
                std.fmt.bufPrintZ(&buf, "-${d}", .{-popup.amount}) catch "-$?";

            const color = if (popup.amount > 0) rl.Color{ .r = 0, .g = 255, .b = 0, .a = alpha } else rl.Color{ .r = 255, .g = 0, .b = 0, .a = alpha };

            const font_size: c_int = @intFromFloat(20.0 * scale);
            rl.drawText(text, @intFromFloat(screen_x - 20.0 * scale), @intFromFloat(screen_y), font_size, color);
        }
    }
}

fn renderUI(world: *World) void {
    const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());

    var buf: [64]u8 = undefined;

    const money_text = std.fmt.bufPrintZ(&buf, "Money: ${d}", .{world.resources.money}) catch "Money: $?";
    rl.drawText(money_text, 10, 30, 30, rl.Color.green);

    const lives_text = std.fmt.bufPrintZ(&buf, "Lives: {d}", .{world.resources.lives}) catch "Lives: ?";
    rl.drawText(lives_text, 10, 60, 25, rl.Color.red);

    const hp_text = std.fmt.bufPrintZ(&buf, "HP: {d}/{d}", .{ world.resources.current_hp, world.resources.max_hp }) catch "HP: ?/?";
    rl.drawText(hp_text, 10, 90, 25, rl.Color.yellow);

    const wave_text = std.fmt.bufPrintZ(&buf, "Wave: {d}", .{world.resources.wave}) catch "Wave: ?";
    rl.drawText(wave_text, @intFromFloat(screen_w - 150), 30, 30, rl.Color.sky_blue);

    const speed_text = std.fmt.bufPrintZ(&buf, "Speed: {d:.1}x", .{world.resources.game_speed}) catch "Speed: ?x";
    rl.drawText(speed_text, @intFromFloat(screen_w - 150), 60, 20, rl.Color.white);

    const bar_width: f32 = 200;
    const bar_height: f32 = 20;
    const bar_x: f32 = 10;
    const bar_y: f32 = 100;

    rl.drawRectangle(@intFromFloat(bar_x), @intFromFloat(bar_y), @intFromFloat(bar_width), @intFromFloat(bar_height), rl.Color.black);

    const total_hp = (world.resources.lives - 1) * world.resources.max_hp + world.resources.current_hp;
    const max_total_hp = world.resources.lives * world.resources.max_hp;
    const health_percentage = @as(f32, @floatFromInt(total_hp)) / @as(f32, @floatFromInt(max_total_hp));

    const health_color = if (health_percentage > 0.5) rl.Color.green else if (health_percentage > 0.25) rl.Color.yellow else rl.Color.red;
    rl.drawRectangle(@intFromFloat(bar_x), @intFromFloat(bar_y), @intFromFloat(bar_width * health_percentage), @intFromFloat(bar_height), health_color);

    const tower_ui_y: c_int = 140;
    const tower_types = [_]struct { t: TowerType, key: [:0]const u8 }{
        .{ .t = .basic, .key = "1" },
        .{ .t = .frost, .key = "2" },
        .{ .t = .cannon, .key = "3" },
        .{ .t = .sniper, .key = "4" },
        .{ .t = .poison, .key = "5" },
    };

    for (tower_types, 0..) |tt, index| {
        const x: c_int = @intCast(10 + index * 60);
        const is_selected = world.resources.selected_tower_type == tt.t;
        const can_afford = world.resources.money >= tt.t.cost();

        const base_color = tt.t.color();
        const color = if (is_selected)
            base_color
        else if (can_afford)
            rl.Color{
                .r = @intFromFloat(@as(f32, @floatFromInt(base_color.r)) * 0.7),
                .g = @intFromFloat(@as(f32, @floatFromInt(base_color.g)) * 0.7),
                .b = @intFromFloat(@as(f32, @floatFromInt(base_color.b)) * 0.7),
                .a = 255,
            }
        else
            rl.Color.dark_gray;

        rl.drawRectangle(x, tower_ui_y, 50, 50, color);
        rl.drawRectangleLines(x, tower_ui_y, 50, 50, rl.Color.black);

        rl.drawText(tt.key, x + 5, tower_ui_y + 5, 20, rl.Color.black);
        const cost_text = std.fmt.bufPrintZ(&buf, "${d}", .{tt.t.cost()}) catch "$?";
        rl.drawText(cost_text, x + 5, tower_ui_y + 30, 15, rl.Color.black);
    }

    if (world.resources.wave_announce_timer > 0) {
        const alpha: u8 = if (world.resources.wave_announce_timer < 1.0) @intFromFloat(world.resources.wave_announce_timer * 255.0) else 255;
        const wave_announce = std.fmt.bufPrintZ(&buf, "WAVE {d}", .{world.resources.wave}) catch "WAVE ?";
        const text_width = rl.measureText(wave_announce, 60);
        rl.drawText(wave_announce, @intFromFloat(screen_w / 2.0 - @as(f32, @floatFromInt(text_width)) / 2.0), @intFromFloat(screen_h / 2.0 - 100), 60, rl.Color{ .r = 255, .g = 204, .b = 0, .a = alpha });
    }

    switch (world.resources.game_state) {
        .waiting_for_wave => {
            const text = "Press SPACE to start wave";
            const text_width = rl.measureText(text, 40);
            rl.drawText(text, @intFromFloat(screen_w / 2.0 - @as(f32, @floatFromInt(text_width)) / 2.0), @intFromFloat(screen_h / 2.0), 40, rl.Color.white);
        },
        .paused => {
            const text = "PAUSED - Press P to resume";
            const text_width = rl.measureText(text, 50);
            rl.drawText(text, @intFromFloat(screen_w / 2.0 - @as(f32, @floatFromInt(text_width)) / 2.0), @intFromFloat(screen_h / 2.0), 50, rl.Color.yellow);
        },
        .game_over => {
            const text = "GAME OVER - Press R to restart";
            const text_width = rl.measureText(text, 50);
            rl.drawText(text, @intFromFloat(screen_w / 2.0 - @as(f32, @floatFromInt(text_width)) / 2.0), @intFromFloat(screen_h / 2.0), 50, rl.Color.red);
        },
        .victory => {
            const text = "VICTORY! Press R to restart";
            const text_width = rl.measureText(text, 50);
            rl.drawText(text, @intFromFloat(screen_w / 2.0 - @as(f32, @floatFromInt(text_width)) / 2.0), @intFromFloat(screen_h / 2.0), 50, rl.Color.green);
        },
        else => {},
    }

    const controls_text = "Controls: 1-5: Tower | LClick: Place | RClick: Sell | U: Upgrade | [/]: Speed | P: Pause";
    rl.drawText(controls_text, 10, @intFromFloat(screen_h - 25), 15, rl.Color.light_gray);
}

pub fn main() !void {
    prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));

    rl.initWindow(1024, 768, "Tower Defense - Zig ECS");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    world.resources = GameResources{
        .money = 200,
        .lives = 1,
        .wave = 0,
        .game_state = .waiting_for_wave,
        .selected_tower_type = .basic,
        .spawn_timer = 0,
        .enemies_to_spawn = .{},
        .mouse_grid_x = null,
        .mouse_grid_y = null,
        .path = .{},
        .wave_announce_timer = 0,
        .game_speed = 1.0,
        .current_hp = 20,
        .max_hp = 20,
    };

    try initializeGrid(&world);
    try createPath(&world);

    while (!rl.windowShouldClose()) {
        const base_dt = rl.getFrameTime();
        const dt = base_dt * world.resources.game_speed;

        try inputSystem(&world);

        if (world.resources.game_state != .paused) {
            try waveSpawningSystem(&world, dt);
            try enemyMovementSystem(&world, dt);
            try towerTargetingSystem(&world);
            try towerShootingSystem(&world, dt);
            try projectileMovementSystem(&world, dt);
            try visualEffectsSystem(&world, dt);
            try updateMoneyPopups(&world, dt);

            try enemyDiedEventHandler(&world);
            try enemySpawnedEventHandler(&world);
            try towerPlacedEventHandler(&world);
            try towerSoldEventHandler(&world);
            try towerUpgradedEventHandler(&world);
            try waveCompletedEventHandler(&world);
        }

        if (world.resources.wave_announce_timer > 0) {
            world.resources.wave_announce_timer -= base_dt;
        }

        world.clearEvents("enemy_reached_end");
        world.clearEvents("projectile_hit");
        world.clearEvents("wave_started");

        rl.beginDrawing();
        rl.clearBackground(rl.Color{ .r = 13, .g = 13, .b = 13, .a = 255 });

        try renderGrid(&world);
        try renderTowers(&world);
        try renderEnemies(&world);
        try renderProjectiles(&world);
        try renderVisualEffects(&world);
        try renderMoneyPopups(&world);
        renderUI(&world);

        rl.endDrawing();
    }

    world.resources.enemies_to_spawn.deinit(allocator);
    world.resources.path.deinit(allocator);
}
