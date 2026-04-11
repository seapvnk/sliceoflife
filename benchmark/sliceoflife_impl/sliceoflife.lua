-- Declarative ECS for LuaJIT with FFI component storage and coroutine scheduling.
-- Authoring surface: Component, System, World, Scheduler, EventBus

local ffi = require "ffi"
local bit = require "bit"

local MAX_ENTITIES   = 65536
local MAX_COMPONENTS = 32

-- Registry
-- Private. Tracks component name → bitmask + FFI array.
-- Grows dynamically as Component() calls arrive.

ffi.cdef [[ typedef struct { uint32_t mask; } ECS_Archetype; ]]

local Registry = (function()
    local _masks  = {}
    local _arrays = {}
    local _count  = 0

    local function define(name, cdef_body)
        assert(not _masks[name], "component already defined: " .. name)
        _count = _count + 1
        assert(_count <= MAX_COMPONENTS, "component limit reached")
        local ctype = "ECS_" .. name
        ffi.cdef("typedef struct { " .. cdef_body .. " } " .. ctype .. ";")
        _masks[name]  = bit.lshift(1, _count - 1)
        _arrays[name] = ffi.new(ctype .. "[?]", MAX_ENTITIES)
    end

    local function mask(names)
        local m = 0
        for _, name in ipairs(names) do
            assert(_masks[name], "unknown component: " .. name)
            m = bit.bor(m, _masks[name])
        end
        return m
    end

    return {
        define = define,
        mask   = mask,
        array  = function(name) return _arrays[name] end,
        known  = function(name) return _masks[name] ~= nil end,
    }
end)()

-- World
-- Singleton. Owns entity slots, archetypes and the entity proxy.

local World = (function()
    local _arch  = ffi.new("ECS_Archetype[?]", MAX_ENTITIES)
    local _top   = 0   -- highest slot ever used
    local _free  = {}

    -- Proxy: e.position → live FFI pointer; e.id → slot number
    local Proxy = {}
    Proxy.__index = function(t, k)
        if k == "id" then return rawget(t, "_id") end
        local arr = Registry.array(k)
        return arr and arr[rawget(t, "_id")] or nil
    end
    Proxy.__newindex = function()
        error("write into component fields directly: e.position.x = v")
    end

    local function _alloc()
        if #_free > 0 then return table.remove(_free) end
        _top = _top + 1
        return _top
    end

    local function spawn(components)
        local id, m = _alloc(), 0
        for name, fields in pairs(components) do
            assert(Registry.known(name), "unknown component: " .. name)
            local arr = Registry.array(name)
            for field, v in pairs(fields) do arr[id][field] = v end
            m = bit.bor(m, Registry.mask({ name }))
        end
        _arch[id].mask = m
        return id
    end

    local function destroy(id)
        _arch[id].mask = 0
        table.insert(_free, id)
    end

    local function add_component(id, name, fields)
        assert(Registry.known(name), "unknown component: " .. name)
        local arr = Registry.array(name)
        for field, v in pairs(fields) do arr[id][field] = v end
        _arch[id].mask = bit.bor(_arch[id].mask, Registry.mask({ name }))
    end

    local function remove_component(id, name)
        assert(Registry.known(name), "unknown component: " .. name)
        _arch[id].mask = bit.band(_arch[id].mask, bit.bnot(Registry.mask({ name })))
    end

    local function has_component(id, name)
        assert(Registry.known(name), "unknown component: " .. name)
        local m = Registry.mask({ name })
        return bit.band(_arch[id].mask, m) == m
    end

    -- Iterator over live entities whose archetype includes required_mask.
    -- Destroyed slots have mask == 0 and are always skipped.
    local function query(required_mask)
        required_mask = required_mask or 0
        if required_mask == 0xFFFFFFFF or required_mask == -1 then
            required_mask = 0
        end
        local i = 0
        return function()
            repeat
                i = i + 1
                if i > _top then return nil end
                local em = _arch[i].mask
                if em ~= 0 and bit.band(em, required_mask) == required_mask then
                    return setmetatable({ _id = i }, Proxy)
                end
            until false
        end
    end

    return {
        spawn            = spawn,
        destroy          = destroy,
        add_component    = add_component,
        remove_component = remove_component,
        has_component    = has_component,
        query            = query,
    }
end)()

-- EventBus
-- Synchronous publish / subscribe.

local EventBus = (function()
    local _listeners = {}

    return {
        subscribe = function(event, fn)
            _listeners[event] = _listeners[event] or {}
            table.insert(_listeners[event], fn)
        end,
        publish = function(event, data)
            for _, fn in ipairs(_listeners[event] or {}) do fn(data) end
        end,
        unsubscribe_all = function(event)
            _listeners[event] = nil
        end,
    }
end)()

-- Component
-- DSL: Component "position" :with "float x, y;"

local function Component(name)
    return setmetatable({}, {
        __index = { with = function(_, body) Registry.define(name, body) end }
    })
end

-- System
-- DSL:
--   local Physics = System "physics"
--       :needs("position", "velocity")
--       :does(function(e, ctx) ... end)

local function System(name)
    local desc = { name = name, _needs = {}, _fn = nil, mask = nil, co = nil }

    function desc:needs(...)
        self._needs = { ... }
        return self
    end

    function desc:does(fn)
        self._fn  = fn
        self.mask = Registry.mask(self._needs)
        return self
    end

    return desc
end

-- Scheduler
-- Wraps each system fn in a coroutine. Chainable :register().

local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new()
    return setmetatable({ _systems = {} }, Scheduler)
end

function Scheduler:register(sys)
    assert(sys._fn and sys.mask,
        "system '" .. sys.name .. "' must call :needs() and :does() before registering")

    local fn, mask = sys._fn, sys.mask

    sys.co = coroutine.create(function()
        local ctx = { dt = 0, frame = 0, world = World, bus = EventBus }
        while true do
            ctx.dt    = coroutine.yield()
            ctx.frame = ctx.frame + 1
            for e in World.query(mask) do fn(e, ctx) end
        end
    end)

    local ok, err = coroutine.resume(sys.co)
    assert(ok, "system '" .. sys.name .. "' failed to boot: " .. tostring(err))

    table.insert(self._systems, sys)
    return self
end

function Scheduler:tick(dt)
    for _, sys in ipairs(self._systems) do
        local ok, err = coroutine.resume(sys.co, dt)
        if not ok then
            io.stderr:write(("[ECS] '%s' crashed: %s\n"):format(sys.name, err))
        end
    end
end

function Scheduler:count() return #self._systems end

-- Public API

return {
    Component = Component,
    System    = System,
    Scheduler = Scheduler,
    World     = World,
    EventBus  = EventBus,
}