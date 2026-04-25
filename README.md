# sliceoflife

Declarative ECS for LuaJIT.

## Benchmark

```
--- Stats: Concord ---
Execution Time: 8.9916 seconds
Memory Delta:   912.11 KB
Total Iterations: 10000
99%  Compiled

--- Stats: SliceOfLife ---
Execution Time: 0.4497 seconds
Memory Delta:   13.30 KB
Total Iterations: 10000
100%  Compiled

specs:
OS: Manjaro Linux x86_64
Host: 81S9 (Lenovo IdeaPad S145-15IWL)
Kernel: Linux 6.12.77-1-MANJARO
CPU: Intel(R) Core(TM) i5-8265U (8) @ 3.90 GHz
GPU: Intel UHD Graphics 620 @ 1.10 GHz [Integrated]
Memory: 5.54 GiB / 7.64 GiB (73%)
```

## Setup

```lua
local ecs       = require "ecs"
local Component = ecs.Component
local System    = ecs.System
local Scheduler = ecs.Scheduler
local World     = ecs.World
local EventBus  = ecs.EventBus
local T         = ecs.Type
```

## Components & Types

### Basic Types
You can define structs and fields using the `Type` DSL for bit-packing to save memory:
```lua
local T = require("sliceoflife").Type

-- Available basic types
T.Float("x")
T.Int("id")
T.Word("flags")

-- Nested bitpacked structs
local Vector2Struct = T.Structs("Vector2", T.Float, {
    position = {"x", "y"},
    velocity = {"dx", "dy"}
})
```

### Pack and Unpack
You can pack and unpack values using the `pack` and `unpack` functions:
```lua
local ECS = require("sliceoflife")
local T = ECS.Type

local packed_float_data = T.pack({ x = 10.5, y = 2.5, z = 3.5 })
local unpacked_float_data = T.unpack(packed_data)

local packed_int_data = T.ipack({ x = 10, y = 2, z = 3 })
local unpacked_int_data = T.iunpack(packed_data)
```

### Components
Components describe data layout in your entities.
```lua
local ECS = require("sliceoflife")
local Component = ECS.Component
local T = ECS.Type

Component "position" :with "float x, y;"
Component "velocity" :with "float x, y;"
-- Using Type DSL
Component "transform" :with (T.Float("x", "y", "rotation"))
```

## The World

The `World` is a singleton that manages entity ID allocation, components, and querying.

```lua
local World = require("sliceoflife").World

-- Spawning an entity
local entity_id = World.spawn({
    position = { x = 0, y = 0 },
    velocity = { x = 1, y = 1 }
})

-- Adding and removing components dynamically
World.add_component(entity_id, "health", { value = 100 })
World.remove_component(entity_id, "velocity")

-- Destroying an entity
World.destroy(entity_id)

-- Saving and loading the world state
World.save("save_file.dat")
World.load("save_file.dat")

-- storing and retrieving data
World.store("my_global", 10)
local my_global = World.store("my_global") -- 10
```

## Systems and Scheduler

### System Definition
Systems define behavior for a specific cross-section of components.

```lua
local System = require("sliceoflife").System

local MovementSystem = System "movement"
    :needs("position", "velocity")
    :does(function(e, ctx)
        -- `e` is an entity proxy giving direct access to component fields
        e.position.x = e.position.x + e.velocity.x * ctx.dt
        e.position.y = e.position.y + e.velocity.y * ctx.dt
    end)
```

### Scheduler
The Scheduler orchestrates systems and passes the context to them.

```lua
local Scheduler = require("sliceoflife").Scheduler
local sched = Scheduler.new()
    -- Register an ECS system
    :register(MovementSystem)
    -- Register a global procedure (runs independently of entities)
    :register(function(ctx) print("Frame started: ", ctx.frame) end)

-- Execute in your game loop
sched:tick(0.016) -- pass delta time
```

## Archetypes
Archetypes define blueprints for entities, making mass spawning highly efficient.

```lua
local Archetype = require("sliceoflife").Archetype

local BaseEnemy = Archetype.new()
    :with("health", { value = 100 })

local SmallEnemy = Archetype.new()
    :extends(BaseEnemy)       -- inherit components from another archetype
    :with("position", { x = 0, y = 0 })
    :with("velocity", { x = 0, y = 0 })
    :rule(function(e, args)   -- modify specific fields on spawn
        e.position.x = args.spawn_x 
        e.velocity.x = math.random() * 10
    end)
    :lock()

-- Usage: Build and Spawn
local enemy_ids = SmallEnemy
    :build(10, { spawn_x = 5 }) -- prepares 10 entity instances
    :spawn()                    -- commits them to the World and returns a table of IDs
```

## Query Builder

Query and manipulate entities fluently without explicit loops.

```lua
-- Fetching all entities matching an archetype
for entity in SmallEnemy:get_all() do
    print(entity.id, entity.position.x)
end

-- Chained queries equivalent to an ORM
SmallEnemy:query()
    :where({ id__in = { 1, 2, 3 } })
    :not_()
    :where({ health = 0 })  -- find alive ones (health != 0 because of not_())
    :take(5)                -- limit result count
    :update({ velocity = { x = 0, y = 0 } })

-- Direct deletion via query chaining
SmallEnemy:query():where({ health = 0 }):delete()
```

## Event Bus
A synchronous global event messenger.

```lua
local EventBus = require("sliceoflife").EventBus

EventBus.subscribe("on_player_death", function(data)
    print("Player died at: ", data.x, data.y)
end)

EventBus.publish("on_player_death", { x = 10, y = 20 })
```

## Job System
A job runner for fire-and-forget logic that spans multiple frames.

```lua
local Jobs = require("sliceoflife").Jobs

-- Submit a job (`ctx.yield` returns execution to the main game engine)
Jobs.submit(function(ctx)
    print("Job started!")
    ctx.yield()
    print("Job resumed next tick!")
end)

-- Job with priority and delay
Jobs.submit(some_func, 10, 5.0) -- priority 10 (lower is run first), starts after 5 seconds

-- Required: run the job tick in your main game loop alongside scheduler tick
Jobs.tick(0.016)
```


**Constraints specific to save/load:**
- `load` must be called before any `World.spawn` , it restores slots by id directly and will collide with freshly allocated ones.
- Save files are not portable across platforms with different endianness or struct padding. Same OS / same compiler is always safe.
- The file format is a flat binary, not human-readable. Don't edit it by hand.

## Constraints

- LuaJIT only (`ffi`, `bit` required).
- Max **65 536** entities, max **32** component types.
- Components must be declared **before** any `World.spawn` or `System :needs` that references them.
- Component names must be unique for the lifetime of the process (no re-definition).
- `e.someComponent = value` raises , write into fields: `e.position.x = v`.
- `World` and `EventBus` are module-level singletons; there is no multi-world support.
- Event dispatch is synchronous , publishing inside a system affects the current tick immediately.

## Roadmap
- [x] Schedule functions that runs independently of entities
- [ ] Save state as csv
- [ ] Load state from csv
- [x] ORM-like query interface with get by id, get by component, get by archetype, map and filter
- [x] Add a proper documentation