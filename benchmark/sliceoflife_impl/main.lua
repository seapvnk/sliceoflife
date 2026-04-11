local ecs = require "sliceoflife"
local Component, System, Scheduler, World = ecs.Component, ecs.System, ecs.Scheduler, ecs.World

Component "position" :with "float x, y;"
Component "velocity" :with "float vx, vy;"

local Physics = System "physics"
    :needs("position", "velocity")
    :does(function(e, ctx)
        e.position.x = e.position.x + e.velocity.vx * ctx.dt
        e.position.y = e.position.y + e.velocity.vy * ctx.dt
    end)

local sched = Scheduler.new():register(Physics)

for i = 1, 10000 do
    World.spawn {
        position = { x = math.random(), y = math.random() },
        velocity = { vx = math.random(), vy = math.random() }
    }
end

local function run(iters)
    for i = 1, iters do sched:tick(0.016) end
end

local function run_benchmark(name, iters)
    -- Initial cleanup for fair start
    collectgarbage("collect")
    local start_mem = collectgarbage("count")
    local start_time = os.clock()

    -- Warmup (JIT compilation)
    for i = 1, 100 do sched:tick(0.016) end

    -- The actual test
    for i = 1, iters do
        sched:tick(0.016)
    end

    local end_time = os.clock()
    local end_mem = collectgarbage("count")

    print(string.format("\n--- Stats: %s ---", name))
    print(string.format("Execution Time: %.4f seconds", end_time - start_time))
    print(string.format("Memory Delta:   %.2f KB", end_mem - start_mem))
    print(string.format("Total Iterations: %d", iters))
end

run_benchmark("SliceOfLife", 5000)