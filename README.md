# sliceoflife

Declarative ECS for LuaJIT.


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

## Components

Declare once at startup. Body is a raw C struct body.

```lua
Component "position" :with (T.Float("x", "y"))
Component "health"   :with (T.Float("value"))
```

## Entities

```lua
local id = World.spawn {
    position = { x = 0, y = 0 },
    health   = { value = 100  },
}

World.add_component(id, "velocity", { x = 10, y = 0 })
World.remove_component(id, "velocity")
World.has_component(id, "health")   -- true / false
World.destroy(id)
```

## Systems

A function that receives one entity and a context bag. No loops, no yields.

```lua
local Physics = System "physics"
    :needs("position", "velocity")
    :does(function(e, ctx)
        e.position.x = e.position.x + e.velocity.x * ctx.dt
        e.position.y = e.position.y + e.velocity.y * ctx.dt
    end)
```

`ctx` fields: `dt`, `frame`, `world`, `bus`.

Entity fields (`e.position`, `e.health`, …) are live FFI pointers — write directly into their fields.

## Scheduler

```lua
local sched = Scheduler.new()
    :register(Physics)
    :register(Decay)

-- game loop
sched:tick(dt)
```

`:register` is chainable. Each system runs once per matching entity per `tick`.


## EventBus

```lua
EventBus.subscribe("entity_died", function(data)
    print("died:", data.id)
end)

-- inside a system:
ctx.bus.publish("entity_died", { id = e.id })

EventBus.unsubscribe_all("entity_died")
```

Dispatch is synchronous — subscribers fire immediately inside `publish`.


## Save / Load

```lua
World.save("world.bin")   -- snapshot every live entity to a binary file
World.load("world.bin")   -- wipe current state and restore from file
```

`save` writes every entity whose archetype mask is non-zero — i.e. every entity that has not been destroyed. `load` wipes all current entities first, then restores the snapshot exactly as it was saved. Entity slot ids are preserved, so any id you cached in Lua remains valid after loading.

**Schema validation.** Before restoring any data, `load` checks that the component names and struct sizes in the file match the current Registry exactly. If you rename a component or change its fields between saves, `load` raises a descriptive error instead of silently corrupting data.

**Typical pattern:**

```lua
-- startup
Component "position" :with (T.Float("x", "y"))
Component "health"   :with (T.Float("value"))

if file_exists("save.bin") then
    World.load("save.bin")   -- must come before any World.spawn
else
    World.spawn { position = { x = 0, y = 0 }, health = { value = 100 } }
end

-- on quit / checkpoint
World.save("save.bin")
```

**Constraints specific to save/load:**
- `load` must be called before any `World.spawn` — it restores slots by id directly and will collide with freshly allocated ones.
- Save files are not portable across platforms with different endianness or struct padding. Same OS / same compiler is always safe.
- The file format is a flat binary, not human-readable. Don't edit it by hand.

## Constraints

- LuaJIT only (`ffi`, `bit` required).
- Max **65 536** entities, max **32** component types.
- Components must be declared **before** any `World.spawn` or `System :needs` that references them.
- Component names must be unique for the lifetime of the process (no re-definition).
- `e.someComponent = value` raises — write into fields: `e.position.x = v`.
- `World` and `EventBus` are module-level singletons; there is no multi-world support.
- Event dispatch is synchronous — publishing inside a system affects the current tick immediately.