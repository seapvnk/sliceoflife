# ecs.lua

Declarative ECS for LuaJIT. Components live in FFI C arrays. Systems run as coroutines ticked by a scheduler.

---

## Setup

```lua
local ecs       = require "ecs"
local Component = ecs.Component
local System    = ecs.System
local Scheduler = ecs.Scheduler
local World     = ecs.World
local EventBus  = ecs.EventBus
```

---

## Components

Declare once at startup. Body is a raw C struct body.

```lua
Component "position" :with "float x, y;"
Component "health"   :with "float value;"
```

---

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

---

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

---

## Scheduler

```lua
local sched = Scheduler.new()
    :register(Physics)
    :register(Decay)

-- game loop
sched:tick(dt)
```

`:register` is chainable. Each system runs once per matching entity per `tick`.

---

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

---

## Constraints

- LuaJIT only (`ffi`, `bit` required).
- Max **65 536** entities, max **32** component types.
- Components must be declared **before** any `World.spawn` or `System :needs` that references them.
- Component names must be unique across the lifetime of the process (no re-definition).
- `e.someComponent = value` raises — you must write into fields: `e.position.x = v`.
- `World` and `EventBus` are module-level singletons; there is no multi-world support.
- Event dispatch is synchronous and not deferred — publishing inside a system affects the current tick immediately.