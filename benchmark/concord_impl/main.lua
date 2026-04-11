local Concord = require("concord")

Concord.component("position", function(c, x, y) c.x, c.y = x, y end)
Concord.component("velocity", function(c, vx, vy) c.vx, c.vy = vx, vy end)

local MoveSystem = Concord.system({ pool = {"position", "velocity"} })
function MoveSystem:update(dt)
    for _, e in ipairs(self.pool) do
        local pos, vel = e.position, e.velocity
        pos.x = pos.x + vel.vx * dt
        pos.y = pos.y + vel.vy * dt
    end
end

local world = Concord.world()
world:addSystem(MoveSystem)

for i = 1, 10000 do
    Concord.entity(world)
        :give("position", math.random(), math.random())
        :give("velocity", math.random(), math.random())
end

local function run_benchmark(name, iters)
    -- Initial cleanup for fair start
    collectgarbage("collect")
    local start_mem = collectgarbage("count")
    local start_time = os.clock()

    -- Warmup (JIT compilation)
    for i = 1, 100 do world:emit("update", 0.016) end

    -- The actual test
    for i = 1, iters do
        world:emit("update", 0.016)
    end

    local end_time = os.clock()
    local end_mem = collectgarbage("count")

    print(string.format("\n--- Stats: %s ---", name))
    print(string.format("Execution Time: %.4f seconds", end_time - start_time))
    print(string.format("Memory Delta:   %.2f KB", end_mem - start_mem))
    print(string.format("Total Iterations: %d", iters))
end

run_benchmark("Concord", 10000)