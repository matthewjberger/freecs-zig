# freECS-Zig

A high-performance, archetype-based Entity Component System (ECS) for Zig.

**Key Features**:

- Archetype-based storage with bitmask queries
- Generational entity handles (prevents ABA problem)
- Contiguous component storage for cache-friendly iteration
- O(1) bit indexing via `@ctz` intrinsic
- Query caching for repeated iteration patterns
- `columnUnchecked` for zero-overhead inner loops
- Batch spawning with pre-allocated capacity
- Compile-time component type registration
- Event queues for decoupled communication
- Resource storage for global state
- System scheduling

This is a Zig port of [freecs](https://github.com/matthewjberger/freecs), a Rust ECS library.

## Quick Start

Add as a dependency or copy `src/freecs.zig` into your project:

```zig
const std = @import("std");
const ecs = @import("freecs");

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    x: f32,
    y: f32,
};

// Define world with component types at compile time
const World = ecs.World(.{ Position, Velocity });

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Spawn entities with components
    const entity = try world.spawn(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .x = 3, .y = 4 },
    });

    // Get components
    if (world.get(entity, Position)) |pos| {
        std.debug.print("Position: ({}, {})\n", .{ pos.x, pos.y });
    }

    // Set components
    _ = world.set(entity, Position{ .x = 10, .y = 20 });

    // Check if entity has a component
    if (world.has(entity, Position)) {
        std.debug.print("Entity has position\n", .{});
    }

    // Despawn entities
    _ = world.despawn(entity);
}
```

## Systems

Systems iterate over archetypes and process entities with matching components:

```zig
const POSITION = World.getBit(Position);
const VELOCITY = World.getBit(Velocity);

fn updatePositions(world: *World, dt: f32) !void {
    const move_mask = POSITION | VELOCITY;
    const matching = try world.getMatchingArchetypes(move_mask, 0);

    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];

        // Get typed slices - pass bit for O(1) lookup (fast path)
        const positions = World.columnWithBit(arch, Position, POSITION);
        const velocities = World.columnWithBit(arch, Velocity, VELOCITY);

        // Process all entities in this archetype
        for (0..arch.entities.items.len) |index| {
            positions[index].x += velocities[index].x * dt;
            positions[index].y += velocities[index].y * dt;
        }
    }
}
```

### Column Access

Two methods are available:

```zig
// Fast path - O(1) via bit index array lookup (requires pre-computed bit)
const positions = World.columnWithBit(arch, Position, POSITION);

// Convenience path - computes bit at call site
const positions = World.column(arch, Position);
```

Use the bit-based version in performance-critical code.

### Batch Spawning

Spawn many entities efficiently with pre-allocated capacity:

```zig
// Spawns 1000 entities with same component value
const entities = try world.spawnBatch(1000, Position, Position{ .x = 0, .y = 0 });
defer world.allocator.free(entities);

// Spawn with mask and custom initialization
const mask = POSITION | VELOCITY;
const entities2 = try world.spawnBatchWithInit(mask, 1000, initCallback);
```

### High-Performance Iteration

For maximum performance, use cached queries and unchecked column access:

```zig
fn updatePositions(world: *World, dt: f32) !void {
    const move_mask = POSITION | VELOCITY;

    // Cached query - archetypes matching this mask are remembered
    const matching = try world.getMatchingArchetypes(move_mask, 0);

    for (matching) |arch_idx| {
        const arch = &world.archetypes.items[arch_idx];

        // Zero-overhead column access
        const positions = World.columnUnchecked(arch, Position);
        const velocities = World.columnUnchecked(arch, Velocity);
        const count = arch.entities.items.len;

        for (0..count) |index| {
            positions[index].x += velocities[index].x * dt;
            positions[index].y += velocities[index].y * dt;
        }
    }
}
```

### Table Iterator

Use the table iterator for cleaner archetype traversal:

```zig
var iter = try world.tableIterator(POSITION | VELOCITY, 0);
while (iter.next()) |result| {
    const arch = result.archetype;
    const positions = World.columnUnchecked(arch, Position);
    const velocities = World.columnUnchecked(arch, Velocity);
    // ...
}
```

## API Reference

### World Management

```zig
var world = World.init(allocator);  // Create a new world
world.deinit();                      // Clean up world resources
const count = world.entityCount();   // Get total entity count
```

### Component Bit Masks

```zig
// Get bitmask for component type (compile-time)
const POSITION = World.getBit(Position);
const VELOCITY = World.getBit(Velocity);

// Combine masks for queries
const MOVABLE = POSITION | VELOCITY;

// Get mask for multiple types at once
const mask = World.getMaskForTypes(.{ Position, Velocity });
```

### Entity Operations

```zig
// Spawn with any number of components
const entity = try world.spawn(.{
    Position{ .x = 0, .y = 0 },
    Velocity{ .x = 1, .y = 1 },
});

// Check if entity is alive
if (world.isAlive(entity)) { ... }

// Despawn entity (slot reused with new generation)
_ = world.despawn(entity);

// Batch despawn
const count = world.despawnBatch(entities);

// Queue despawn for deferred removal
try world.queueDespawn(entity);
world.applyDespawns();
```

### Component Access

```zig
// Get component (returns null if not present)
if (world.get(entity, Position)) |pos| { ... }

// Get unchecked (when you know the component exists)
const pos = world.getUnchecked(entity, Position);

// Set component value
_ = world.set(entity, Position{ .x = 10, .y = 20 });

// Check if entity has component
if (world.has(entity, Position)) { ... }

// Check multiple components
if (world.hasComponents(entity, POSITION | VELOCITY)) { ... }

// Get entity's component mask
if (world.componentMask(entity)) |mask| { ... }
```

### Adding/Removing Components

```zig
// Add component to existing entity (moves to new archetype)
_ = try world.addComponent(entity, Velocity{ .x = 1, .y = 0 });

// Remove component from entity
_ = try world.removeComponent(entity, Velocity);
```

### Query Operations

```zig
// Count entities matching query
const count = try world.queryCount(POSITION | VELOCITY, 0);

// Get first entity matching query
if (try world.queryFirst(POSITION, 0)) |entity| { ... }

// Get all entities matching query
var entities = try world.queryEntities(POSITION, 0);
defer entities.deinit(world.allocator);
```

## Events

Event queues allow decoupled communication between systems:

```zig
const EnemyDied = struct {
    entity_id: u32,
    reward: u32,
};

const GameWorld = ecs.WorldConfig(.{
    .components = .{ Position, Velocity },
    .events = .{
        .enemy_died = EnemyDied,
    },
});

var world = GameWorld.init(allocator);

// Send events
try world.send("enemy_died", EnemyDied{ .entity_id = 1, .reward = 100 });

// Process events
for (world.eventSlice("enemy_died")) |event| {
    // Handle event
}

// Clear events after processing
world.clearEvents("enemy_died");
// Or clear all events
world.clearAllEvents();
```

## Resources

Global state accessible throughout the ECS:

```zig
const GameResources = struct {
    score: u32,
    lives: u32,
};

const GameWorld = ecs.WorldConfig(.{
    .components = .{ Position, Velocity },
    .Resources = GameResources,
});

var world = GameWorld.init(allocator);
world.resources = GameResources{ .score = 0, .lives = 3 };

// Access resources
world.resources.score += 100;
```

## System Scheduling

Organize systems into a schedule:

```zig
fn movementSystem(world: *GameWorld) !void {
    // Update positions
}

fn renderSystem(world: *GameWorld) !void {
    // Render entities
}

var schedule = ecs.Schedule(GameWorld).init(allocator);
defer schedule.deinit();

_ = try schedule.addSystem(movementSystem);
_ = try schedule.addSystem(renderSystem);

// Run all systems in order
try schedule.run(&world);
```

## Example: Boids Simulation

See `examples/boids.zig` for a complete boids flocking simulation using raylib:

```
zig build run-boids
```

Controls:
- **Space**: Pause/unpause
- **+/-**: Add/remove 1000 boids
- **Arrow keys**: Adjust alignment/cohesion weights
- **Left mouse**: Attract boids
- **Right mouse**: Repel boids

## Running Tests

```
zig build test
```

## Building

```
zig build
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE.md) file for details.
