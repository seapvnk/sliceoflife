-- Declarative ECS for LuaJIT with FFI component storage and coroutine scheduling.
-- Authoring surface: Component, System, World, Scheduler, EventBus

local ffi = require "ffi"
local bit = require "bit"

local MAX_ENTITIES   = 65536
local MAX_COMPONENTS = 32

-- Registry
-- Private. Tracks component name -> bitmask + FFI array.
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

    local function names()
        local names = {}
        for name, _ in pairs(_arrays) do
            table.insert(names, name)
        end
        return names
    end

    local function sizeof(name)
        return ffi.sizeof("ECS_" .. name)
    end

    return {
        define = define,
        mask   = mask,
        names  = names,
        sizeof = sizeof,
        array  = function(name) return _arrays[name] end,
        arrays = _arrays,
        known  = function(name) return _masks[name] ~= nil end,
    }
end)()

-- World
-- Singleton. Owns entity slots, archetypes and the entity proxy.

local World = (function()
    local _arch  = ffi.new("ECS_Archetype[?]", MAX_ENTITIES)
    local _top   = 0   -- highest slot ever used
    local _free  = {}

    local _arrays = Registry.arrays

    -- Proxy: e.position -> live FFI pointer; e.id -> slot number
    local Proxy = {}
    Proxy.__index = function(t, k)
        local i = t._state[1]
        if k == "id" then return i end
        local arr = _arrays[k]
        return arr and arr[i] or nil
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
    local function query_next(state, _)
        local req = state.mask
        local i = state[1]
        repeat
            i = i + 1
            if i > _top then return nil end
            local em = _arch[i].mask
            if em ~= 0 and bit.band(em, req) == req then
                state[1] = i
                return state.proxy
            end
        until false
    end

    local function query(required_mask)
        required_mask = required_mask or 0
        if required_mask == 0xFFFFFFFF or required_mask == -1 then
            required_mask = 0
        end
        local state = { 0, mask = required_mask }
        state.proxy = setmetatable({ _state = state }, Proxy)
        return query_next, state, nil
    end

    -- Binary format
    -- Header:
    --   [4b] magic "SOL\1"
    --   [4b] component count N
    --   per component: [1b] name length, [Nb] name, [4b] sizeof(struct)
    -- Records (every live slot, mask ~= 0):
    --   [4b] slot id, [4b] archetype mask
    --   per set component: [sizeof] raw struct bytes
 
    local MAGIC = "SOL\1"
 
    local function u32le(n)
        return string.char(
            bit.band(n,            0xFF),
            bit.band(bit.rshift(n,  8), 0xFF),
            bit.band(bit.rshift(n, 16), 0xFF),
            bit.band(bit.rshift(n, 24), 0xFF))
    end
 
    local function save(path)
        local f     = assert(io.open(path, "wb"), "cannot open for write: " .. path)
        local names = Registry.names()
        local buf   = ffi.new("uint8_t[65536]")
 
        f:write(MAGIC)
        f:write(u32le(#names))
        for _, name in ipairs(names) do
            f:write(string.char(#name))
            f:write(name)
            f:write(u32le(Registry.sizeof(name)))
        end
 
        for id = 1, _top do
            local m = _arch[id].mask
            if m ~= 0 then
                f:write(u32le(id))
                f:write(u32le(m))
                for _, name in ipairs(names) do
                    local cm = Registry.mask({ name })
                    if bit.band(m, cm) == cm then
                        local sz = Registry.sizeof(name)
                        ffi.copy(buf, Registry.array(name)[id], sz)
                        f:write(ffi.string(buf, sz))
                    end
                end
            end
        end
 
        f:close()
    end
 
    local function read_u32(f)
        local b = assert(f:read(4), "unexpected EOF")
        local a, b2, c, d = b:byte(1, 4)
        return bit.bor(a, bit.lshift(b2, 8), bit.lshift(c, 16), bit.lshift(d, 24))
    end
 
    local function load(path)
        local f = assert(io.open(path, "rb"), "cannot open for read: " .. path)
 
        assert(f:read(4) == MAGIC, "not a valid ECS save file")

        local names = Registry.names()
 
        local n = read_u32(f)
        assert(n == #names,
            ("save has %d component types, registry has %d"):format(n, #names))
        for i = 1, n do
            local name = f:read(f:read(1):byte())
            local sz   = read_u32(f)
            assert(name == names[i],
                ("component mismatch at slot %d: file='%s' registry='%s'")
                :format(i, name, names[i]))
            assert(sz == Registry.sizeof(name),
                ("size mismatch for '%s': file=%d registry=%d")
                :format(name, sz, Registry.sizeof(name)))
        end
 
        -- wipe current state before restoring
        for id = 1, _top do _arch[id].mask = 0 end
        _top  = 0
        _free = {}
 
        local buf = ffi.new("uint8_t[65536]")
        while true do
            local hdr = f:read(4)
            if not hdr or #hdr < 4 then break end
            local a, b2, c, d = hdr:byte(1, 4)
            local id = bit.bor(a, bit.lshift(b2, 8), bit.lshift(c, 16), bit.lshift(d, 24))
            local m  = read_u32(f)
 
            _arch[id].mask = m
            if id > _top then _top = id end
 
            for _, name in ipairs(names) do
                local cm = Registry.mask({ name })
                if bit.band(m, cm) == cm then
                    local sz  = Registry.sizeof(name)
                    local raw = assert(f:read(sz), "truncated data for: " .. name)
                    ffi.copy(buf, raw, sz)
                    ffi.copy(Registry.array(name)[id], buf, sz)
                end
            end
        end
 
        f:close()
    end

    return {
        spawn            = spawn,
        destroy          = destroy,
        add_component    = add_component,
        remove_component = remove_component,
        has_component    = has_component,
        query            = query,
        query_next       = query_next,
        save             = save,
        load             = load,
        arch             = _arch,
        top              = function() return _top end,
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

-- Type
-- DSL: 
--     Type.Float "x", Type.Float "y"
--     Type.Int "id"
local Type = {}

local function _type(typ, ...)
    local args = { ... }
    local str = ""
    for _, arg in ipairs(args) do
        str = str .. typ .. " " .. arg .. ";"
    end
    return str
end

local _basic_types = { Float = "float", Int = "int", Word = "uint64_t" }
for k, v in pairs(_basic_types) do Type[k] = function(...) return _type(v, ...) end end

local MIN_BOUND = -1e6
local MAX_BOUND =  1e6
 
local u64  = ffi.new("uint64_t", 0)
local POW2 = ffi.new("uint64_t[64]")
POW2[0] = 1
for i = 1, 63 do POW2[i] = POW2[i - 1] * 2ULL end
local ZERO = ffi.new("uint64_t", 0)
 
local function U(n) return ffi.cast("uint64_t", n) end
 
-- encode a float in [MIN_BOUND, MAX_BOUND] into b bits
local function qencode(v, b)
    local levels = 2^b - 1
    local t = (v - MIN_BOUND) / (MAX_BOUND - MIN_BOUND)
    t = math.max(0, math.min(1, t))
    return math.floor(t * levels + 0.5)
end
 
local function qdecode(q, b)
    local levels = 2^b - 1
    return MIN_BOUND + (q / levels) * (MAX_BOUND - MIN_BOUND)
end
 
function Type.pack(t)
    -- collect keys in sorted order for determinism
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end
    table.sort(keys)
    local n = #keys
    assert(n >= 1 and n <= 15, "pack supports 1–15 fields")
 
    local values = {}
    for i, k in ipairs(keys) do values[i] = t[k] end
 
    local min, max = values[1], values[1]
    for i = 2, n do
        if values[i] < min then min = values[i] end
        if values[i] > max then max = values[i] end
    end
    if min == max then max = min + 1 end
 
    local bits_per = math.floor(40 / n)
    local levels   = 2^bits_per - 1
 
    local qmin_enc = qencode(min, 10)
    local qmax_enc = qencode(max, 10)
    
    local qmin_dec = qdecode(qmin_enc, 10)
    local qmax_dec = qdecode(qmax_enc, 10)
 
    if qmin_dec > min then
        qmin_enc = math.max(0, qmin_enc - 1)
        qmin_dec = qdecode(qmin_enc, 10)
    end
    if qmax_dec < max then
        qmax_enc = math.min(1023, qmax_enc + 1)
        qmax_dec = qdecode(qmax_enc, 10)
    end
    if qmax_dec == qmin_dec then
        qmax_enc = math.min(1023, qmax_enc + 1)
        qmax_dec = qdecode(qmax_enc, 10)
        if qmax_dec == qmin_dec then
            qmin_enc = math.max(0, qmin_enc - 1)
            qmin_dec = qdecode(qmin_enc, 10)
        end
    end
 
    -- quantize payload
    local word = ZERO
    for i, v in ipairs(values) do
        local norm = (v - qmin_dec) / (qmax_dec - qmin_dec)
        local q    = math.floor(math.max(0, math.min(1, norm)) * levels + 0.5)
        word = word + U(q) * POW2[(i - 1) * bits_per]
    end
 
    -- pack min, max, n into top 24 bits
    word = word
         + U(n)               * POW2[40]
         + U(qmax_enc)        * POW2[44]
         + U(qmin_enc)        * POW2[54]
 
    return word
end
 
function Type.unpack(encoded, keys)
    table.sort(keys)
    local n = #keys
 
    local mask4  = U(0xF)
    local mask10 = U(0x3FF)
 
    local n_dec      = tonumber((encoded / POW2[40]) % (mask4  + U(1)))
    local qmax       = tonumber((encoded / POW2[44]) % (mask10 + U(1)))
    local qmin_enc   = tonumber((encoded / POW2[54]) % (mask10 + U(1)))
 
    assert(n_dec == n,
        ("unpack: encoded has %d fields, keys list has %d"):format(n_dec, n))
 
    local min      = qdecode(qmin_enc, 10)
    local max      = qdecode(qmax,     10)
    local bits_per = math.floor(40 / n)
    local levels   = 2^bits_per - 1
    local mask_p   = U(levels)
 
    local out = {}
    for i, k in ipairs(keys) do
        local shifted = encoded / POW2[(i - 1) * bits_per]
        local q       = tonumber(shifted % (mask_p + U(1)))
        out[k]        = min + (q / levels) * (max - min)
    end
    return out
end
 
function Type.ipack(t)
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end
    table.sort(keys)
    local n = #keys
    assert(n >= 1 and n <= 15, "ipack supports 1–15 fields")
 
    local bits_per = math.floor(60 / n)
    local levels   = U(2^bits_per - 1)
 
    local word = U(n) * POW2[60]
    for i, k in ipairs(keys) do
        local v = t[k]
        assert(v >= 0 and v == math.floor(v),
            "ipack: all values must be non-negative integers")
        local q = U(v)
        assert(q <= levels,
            ("ipack: value %d exceeds %d-bit capacity"):format(v, bits_per))
        word = word + q * POW2[(i - 1) * bits_per]
    end
    return word
end
 
function Type.iunpack(encoded, keys)
    table.sort(keys)
    local n = #keys
 
    local mask4 = U(0xF)
    local n_dec = tonumber((encoded / POW2[60]) % (mask4 + U(1)))
    assert(n_dec == n,
        ("iunpack: encoded has %d fields, keys list has %d"):format(n_dec, n))
 
    local bits_per = math.floor(60 / n)
    local mask_p   = U(2^bits_per - 1)
 
    local out = {}
    for i, k in ipairs(keys) do
        local shifted = encoded / POW2[(i - 1) * bits_per]
        out[k] = tonumber(shifted % (mask_p + U(1)))
    end
    return out
end

-- Component
-- DSL:
--      Component "position" :with "float x, y;"
--      Component "position" :with Type.Float("x", "y")

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
    local desc = { name = name, _needs = {}, _fn = nil, mask = nil, ctx = nil }

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
-- Chainable :register().

local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new()
    return setmetatable({ _systems = {} }, Scheduler)
end

function Scheduler:register(sys)
    assert(sys._fn and sys.mask,
        "system '" .. sys.name .. "' must call :needs() and :does() before registering")

    sys.ctx = { dt = 0, frame = 0, world = World, bus = EventBus }
    local _, state = World.query(sys.mask)
    sys.state = state
    
    table.insert(self._systems, sys)
    return self
end

function Scheduler:tick(dt)
    local band = bit.band
    local arch = World.arch
    for _, sys in ipairs(self._systems) do
        local ctx = sys.ctx
        ctx.dt = dt
        ctx.frame = ctx.frame + 1
        local fn = sys._fn
        local req = sys.mask
        local state = sys.state
        local proxy = state.proxy
        local top = World.top()

        for i = 1, top do
            local em = arch[i].mask
            if em ~= 0 and band(em, req) == req then
                state[1] = i
                fn(proxy, ctx)
            end
        end
    end
end

function Scheduler:count() return #self._systems end

return {
    Type      = Type,
    Component = Component,
    System    = System,
    Scheduler = Scheduler,
    World     = World,
    EventBus  = EventBus,
}