-- Run with:  luajit tests.lua

local ecs       = require "src.sliceoflife"
local T         = ecs.Type
local Component = ecs.Component
local System    = ecs.System
local Scheduler = ecs.Scheduler
local World     = ecs.World
local EventBus  = ecs.EventBus
local Jobs      = ecs.Jobs

-- Harness

local passed, failed = 0, 0

local function describe(label)
    io.write("\n  " .. label .. "\n")
end

local function it(label, fn)
    local ok, err = pcall(fn)
    if ok then
        io.write(("    ✓ %s\n"):format(label))
        passed = passed + 1
    else
        io.write(("    ✗ %s\n      %s\n"):format(label, tostring(err)))
        failed = failed + 1
    end
end

local function eq(a, b)
    assert(a == b, ("expected %s, got %s"):format(tostring(b), tostring(a)))
end

local function near(a, b, tol)
    tol = tol or 1e-4
    assert(math.abs(a - b) <= tol,
        ("expected ~%s, got %s"):format(tostring(b), tostring(a)))
end

local function is_true(v, msg)  assert(v,     msg or "expected true")  end
local function is_false(v, msg) assert(not v, msg or "expected false") end

local function errors(fn, pattern)
    local ok, err = pcall(fn)
    assert(not ok, "expected an error but none was raised")
    if pattern then
        assert(tostring(err):find(pattern),
            ("error '%s' did not match '%s'"):format(err, pattern))
    end
end

-- helper: find a specific entity id in a query result
local function find(mask, id)
    for e in World.query(mask) do
        if e.id == id then return e end
    end
end

-- Component declarations
-- All components are registered once here; Registry is module-level state.

Component "position" :with (T.Float("x", "y"))
Component "velocity" :with (T.Float("x", "y"))
Component "health"   :with (T.Float "value")
Component "lifetime" :with (T.Float "remaining")
Component "tag"      :with (T.Int "id")
Component "hero_stats" :with (T.Structs("hero_stats", T.Int, { attr = {"str", "dex", "int"}, mod = {"attack", "defense"} }))

-- Tests

describe("Registry")

    it("rejects duplicate component names", function()
        errors(function() Component "position" :with (T.Float("x", "y")) end,
               "already defined")
    end)

    it("rejects unknown component in System :needs()", function()
        errors(function()
            System "ghost_sys" :needs("ghost") :does(function() end)
        end, "unknown component")
    end)

describe("Type")

    it("pack and unpack almost preserving values", function()
        local t = { x = 32200.11, y = 44.56 }
        local encoded = T.pack(t)
        local decoded = T.unpack(encoded, { "x", "y" })
        near(decoded.x, 32200.11, 1e-1)
        near(decoded.y, 44.56, 1e-1)
    end)

    it("pack and unpack on integers", function()
        local attr = { str = 10, int = 10, chr = 10, dex = 10, con = 10, wis = 10, cha = 10}
        local encoded = T.ipack(attr)
        local decoded = T.iunpack(encoded, { "str", "int", "chr", "dex", "con", "wis", "cha"})
        eq(decoded.str, 10)
        eq(decoded.int, 10)
        eq(decoded.chr, 10)
        eq(decoded.dex, 10)
        eq(decoded.con, 10)
        eq(decoded.wis, 10)
        eq(decoded.cha, 10)
    end)

    it("spack and sunpack on int structs", function()
        local data = {
            attr = { str = 15, dex = 14, int = 10 },
            mod  = { attack = 12, defense = 8 }
        }
        local packed = T.spack("hero_stats", data)
        local unpacked = T.sunpack("hero_stats", packed)
        
        eq(unpacked.attr.str, 15)
        eq(unpacked.attr.dex, 14)
        eq(unpacked.attr.int, 10)
        eq(unpacked.mod.attack, 12)
        eq(unpacked.mod.defense, 8)
    end)

describe("World.spawn / proxy")

    it("spawn returns a numeric id", function()
        local id = World.spawn { position = { x = 1, y = 2 } }
        is_true(type(id) == "number")
        is_true(id >= 1)
    end)

    it("proxy reads spawned component fields", function()
        local id = World.spawn { position = { x = 3, y = 7 } }
        local e  = find(0xFFFFFFFF, id)
        is_true(e ~= nil, "entity not found")
        near(e.position.x, 3)
        near(e.position.y, 7)
    end)

    it("proxy field writes persist", function()
        local id = World.spawn { position = { x = 0, y = 0 } }
        local e  = find(0xFFFFFFFF, id)
        e.position.x = 55
        e.position.y = 77
        local e2 = find(0xFFFFFFFF, id)
        near(e2.position.x, 55)
        near(e2.position.y, 77)
    end)

    it("proxy exposes .id equal to spawn return", function()
        local id = World.spawn { position = { x = 0, y = 0 } }
        local e  = find(0xFFFFFFFF, id)
        eq(e.id, id)
    end)

    it("proxy assignment at the top level raises an error", function()
        local id = World.spawn { position = { x = 0, y = 0 } }
        local e  = find(0xFFFFFFFF, id)
        errors(function() e.position = {} end)
    end)

describe("World component mutation")

    it("add_component attaches and is reflected by has_component", function()
        local id = World.spawn { position = { x = 0, y = 0 } }
        is_false(World.has_component(id, "health"))
        World.add_component(id, "health", { value = 50 })
        is_true(World.has_component(id, "health"))
    end)

    it("add_component value is readable via proxy", function()
        local id = World.spawn { position = { x = 0, y = 0 } }
        World.add_component(id, "health", { value = 75 })
        local e = find(0xFFFFFFFF, id)
        near(e.health.value, 75)
    end)

    it("remove_component clears has_component", function()
        local id = World.spawn {
            position = { x = 0, y = 0 },
            health   = { value = 100 },
        }
        World.remove_component(id, "health")
        is_false(World.has_component(id, "health"))
    end)

    it("add_component with unknown name raises", function()
        local id = World.spawn { position = { x = 0, y = 0 } }
        errors(function() World.add_component(id, "ghost", {}) end,
               "unknown component")
    end)

describe("World.save / World.load")

    it("save and load preserve entity data", function()
        local id = World.spawn { position = { x = 1, y = 2 }, health = { value = 100 } }
        local test_filename = "test_save_0000.bin"
        World.save(test_filename)
        World.destroy(id)
        World.load(test_filename)
        local e = find(0xFFFFFFFF, id)
        is_true(e ~= nil, "entity should exist after load")
        near(e.position.x, 1)
        near(e.position.y, 2)
        near(e.health.value, 100)

        os.remove(test_filename)
    end)

describe("World.reset")

    it("reset clears all entities", function()
        local id = World.spawn { position = { x = 1, y = 2 }, health = { value = 100 } }
        World.reset()
        is_false(find(0xFFFFFFFF, id) ~= nil, "entity should not exist after reset")
    end)

describe("World.query archetype filtering")

    it("query with full mask returns only matching entities", function()
        local full     = World.spawn { position = { x = 1, y = 1 },
                                       velocity = { x = 1, y = 0 } }
        local pos_only = World.spawn { position = { x = 5, y = 5 } }

        local sys = System "filter_test"
            :needs("position", "velocity")
            :does(function() end)

        is_true (find(sys.mask, full)     ~= nil, "full entity should match")
        is_false(find(sys.mask, pos_only) ~= nil, "pos-only should not match")
    end)

    it("query with mask 0xFFFFFFFF still skips destroyed slots", function()
        local id = World.spawn { position = { x = 99, y = 99 } }
        World.destroy(id)
        is_false(find(0xFFFFFFFF, id) ~= nil, "destroyed entity must not appear")
    end)

describe("World.destroy")

    it("destroyed entity is excluded from query", function()
        local id = World.spawn { position = { x = 10, y = 10 } }
        World.destroy(id)
        is_false(find(0xFFFFFFFF, id) ~= nil)
    end)

    it("slot can be reused after destroy", function()
        local id1 = World.spawn { position = { x = 0, y = 0 } }
        World.destroy(id1)
        local id2 = World.spawn { position = { x = 1, y = 1 } }
        -- id2 may or may not equal id1 depending on free-list; just verify it is alive
        is_true(find(0xFFFFFFFF, id2) ~= nil)
    end)

describe("Jobs")

    it("submit and tick", function()
        local started = false
        local finished = false
        Jobs.submit(function(ctx)
            started = true
            ctx.yield()
            finished = true
        end)
        Jobs.tick(0.1)
        is_true(started)
        is_false(finished)
        Jobs.tick(0.1)
        is_true(finished)
    end)

    it("delay", function()
        local finished = false
        Jobs.submit(function(ctx)
            finished = true
        end, 0, 0.1)
        Jobs.tick(0.05)
        is_false(finished)
        Jobs.tick(0.05)
        is_false(finished)
        Jobs.tick(0.1)
        is_true(finished)
    end)
    
describe("World.store")

    it("store and retrieve data", function()
        local id = World.spawn { position = { x = 0, y = 0 } }
        World.store(id, { data = "hello" })
        eq(World.store(id).data, "hello")
    end)

describe("System DSL")

    it(":needs :does produces a descriptor with mask and _fn", function()
        local sys = System "dsl_test"
            :needs("position")
            :does(function() end)
        is_true(sys.mask ~= nil)
        is_true(sys.mask > 0)
        is_true(type(sys._fn) == "function")
        eq(sys.name, "dsl_test")
    end)

    it("registering a system without :does() raises", function()
        local sys = System "no_does" :needs("position")
        errors(function() Scheduler.new():register(sys) end)
    end)

describe("Scheduler")

    it(":register returns self for chaining", function()
        local sched = Scheduler.new()
        local sys   = System "chain" :needs("position") :does(function() end)
        eq(sched:register(sys), sched)
    end)

    it(":count reflects registered systems", function()
        local sched = Scheduler.new()
        eq(sched:count(), 0)
        sched:register(System "c1" :needs("position") :does(function() end))
        eq(sched:count(), 1)
        sched:register(System "c2" :needs("health")   :does(function() end))
        eq(sched:count(), 2)
    end)

describe("Scheduler:tick — integration")

    it("physics moves entity over one tick", function()
        local id = World.spawn {
            position = { x = 0,   y = 0   },
            velocity = { x = 120, y = 60  },
        }
        local sys = System "phys"
            :needs("position", "velocity")
            :does(function(e, ctx)
                e.position.x = e.position.x + e.velocity.x * ctx.dt
                e.position.y = e.position.y + e.velocity.y * ctx.dt
            end)
        Scheduler.new():register(sys):tick(1/60)
        local e = find(sys.mask, id)
        near(e.position.x, 120/60, 1e-3)
        near(e.position.y, 60/60,  1e-3)
    end)

    it("system fn is called once per matching entity per tick", function()
        local hits = 0
        local ids = {
            World.spawn { health = { value = 10 } },
            World.spawn { health = { value = 10 } },
            World.spawn { health = { value = 10 } },
        }
        local sys = System "hit_counter"
            :needs("health")
            :does(function(e, ctx)
                for _, id in ipairs(ids) do
                    if e.id == id then hits = hits + 1 end
                end
            end)
        Scheduler.new():register(sys):tick(1/60)
        eq(hits, 3)
    end)

    it("ctx.frame increments each tick", function()
        local last_frame
        World.spawn { position = { x = 0, y = 0 } }
        local sys = System "frame_check"
            :needs("position")
            :does(function(e, ctx) last_frame = ctx.frame end)
        local sched = Scheduler.new():register(sys)
        sched:tick(1/60)
        sched:tick(1/60)
        sched:tick(1/60)
        eq(last_frame, 3)
    end)

    it("ctx.dt carries the value passed to tick", function()
        local seen
        World.spawn { position = { x = 0, y = 0 } }
        local sys = System "dt_check"
            :needs("position")
            :does(function(e, ctx) seen = ctx.dt end)
        Scheduler.new():register(sys):tick(0.12345)
        near(seen, 0.12345)
    end)

    it("two systems on the same entity see each other's writes", function()
        local id = World.spawn {
            position = { x = 0,   y = 0   },
            velocity = { x = 60,  y = 0   },
            health   = { value = 100       },
        }
        local move = System "two_move"
            :needs("position", "velocity")
            :does(function(e, ctx)
                e.position.x = e.position.x + e.velocity.x * ctx.dt
            end)
        local decay = System "two_decay"
            :needs("health")
            :does(function(e, ctx)
                e.health.value = e.health.value - 20 * ctx.dt
            end)
        Scheduler.new():register(move):register(decay):tick(1.0)
        local e = find(0xFFFFFFFF, id)
        near(e.position.x, 60,  0.01)
        near(e.health.value, 80, 0.01)
    end)

describe("EventBus")

    it("subscriber receives published data", function()
        local got
        EventBus.subscribe("ev_a", function(d) got = d.v end)
        EventBus.publish("ev_a", { v = 42 })
        eq(got, 42)
        EventBus.unsubscribe_all("ev_a")
    end)

    it("multiple subscribers each fire", function()
        local log = {}
        EventBus.subscribe("ev_b", function(d) log[#log+1] = "x:" .. d.n end)
        EventBus.subscribe("ev_b", function(d) log[#log+1] = "y:" .. d.n end)
        EventBus.publish("ev_b", { n = 7 })
        eq(#log, 2)
        eq(log[1], "x:7")
        eq(log[2], "y:7")
        EventBus.unsubscribe_all("ev_b")
    end)

    it("publish with no subscribers is a no-op", function()
        EventBus.publish("ev_nobody", { x = 1 })  -- must not error
    end)

    it("system publishes via ctx.bus during tick", function()
        local fired = false
        EventBus.subscribe("died", function(d)
            if d.id then fired = true end
        end)
        local id = World.spawn { health = { value = 1 } }
        local sys = System "killer"
            :needs("health")
            :does(function(e, ctx)
                e.health.value = e.health.value - 10
                if e.health.value <= 0 then
                    ctx.bus.publish("died", { id = e.id })
                end
            end)
        Scheduler.new():register(sys):tick(1/60)
        is_true(fired, "entity_died event not fired")
        EventBus.unsubscribe_all("died")
    end)

describe("Archetypes")

    it("creates an archetype with a struct component and spawns it", function()
        local HeroArch = ecs.Archetype.new()
            :with("position", { x = 0, y = 0 })
            :with("hero_stats", { attr = { str=10, dex=10, int=10 }, mod = { attack=1, defense=1 } })
            :rule(function(e, args)
                e.position.x = args.x or 0
                e.position.y = args.y or 0
                e.hero_stats.attr.str = args.str or 10
            end)
            :lock()
            
        local ids = HeroArch:build(1, { x = 10, y = 20, str = 18 }):spawn()
        local id = ids[1]
        local e = find(0xFFFFFFFF, id)
        
        is_true(e ~= nil)
        near(e.position.x, 10)
        near(e.position.y, 20)
        
        local unpacked = T.sunpack("hero_stats", { attr = e.hero_stats.attr, mod = e.hero_stats.mod })
        eq(unpacked.attr.str, 18)
        eq(unpacked.attr.dex, 10)
        eq(unpacked.mod.attack, 1)
    end)

describe("Query")

    it("where clauses are correctly stored and negate applies to the next", function()
        local q = ecs.Query.new():where({ id = 10 }):not_():where({ component__in = { "position" } })
        local req_mask = q:get()
        -- id = 10 is positive
        -- position is negated -> req_mask should be 0 since it is negated
        is_true(req_mask == 0)
    end)

    it("and_ merges queries", function()
        local q1 = ecs.Query.new():where({ id = 1 })
        local q2 = ecs.Query.new():where({ id__not = 2 })
        q1:and_(q2)
        local rm = q1:get()
        is_true(#q1._wheres == 2)
    end)

describe("ArchetypeQuery")

    it("get() filters appropriately and take(n) limits results", function()
        ecs.World.reset()
        local a = ecs.World.spawn { position = { x=1, y=2 }, health = { value = 1 } }
        local b = ecs.World.spawn { position = { x=3, y=4 } }
        local c = ecs.World.spawn { position = { x=5, y=6 } }
        
        local DummyArch = ecs.Archetype.new():with("position", {x=0,y=0})
        
        -- get_all should return all 3
        local i = 0
        for _ in DummyArch:get_all() do i = i + 1 end
        eq(i, 3)

        -- take(2) limits to 2
        i = 0
        for _ in DummyArch:query():take(2):get() do i = i + 1 end
        eq(i, 2)

        -- where({ id__not_in })
        i = 0
        for e in DummyArch:query():where({ id__not_in = {a, b} }):get() do
            i = i + 1
            eq(e.id, c)
        end
        eq(i, 1)
        
        -- component__in positive
        i = 0
        for e in DummyArch:query():where({ component__in = { "health" } }):get() do
            i = i + 1
            eq(e.id, a)
        end
        eq(i, 1)
    end)

    it("update() modifies components", function()
        ecs.World.reset()
        ecs.World.spawn { position = { x=1, y=2 } }
        ecs.World.spawn { position = { x=3, y=4 } }
        
        local DummyArch = ecs.Archetype.new():with("position", {x=0,y=0})
        DummyArch:query():update({ position = { x = 99 } })
        
        for e in DummyArch:get_all() do
            eq(e.position.x, 99)
        end
    end)

    it("delete() removes components", function()
        ecs.World.reset()
        ecs.World.spawn { position = { x=1, y=2 } }
        ecs.World.spawn { position = { x=3, y=4 } }
        
        local DummyArch = ecs.Archetype.new():with("position", {x=0,y=0})
        DummyArch:query():delete()
        
        local i = 0
        for _ in DummyArch:get_all() do i = i + 1 end
        eq(i, 0)
    end)

-- Results

io.write(("\n  %d passed  %d failed\n\n"):format(passed, failed))
if failed > 0 then os.exit(1) end