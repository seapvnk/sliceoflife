local ecs = require "../src/sliceoflife"
local Component, System, Scheduler, World, T = ecs.Component, ecs.System, ecs.Scheduler, ecs.World, ecs.Type

Component "position" :with (T.Float("x", "y"))
Component "size"     :with (T.Float("w", "h"))
Component "physics"  :with (T.Int("exists"))
Component "paddle"   :with (T.Int("id"))

local lp = love.physics
local world_box2d = lp.newWorld(0, 0, true)

-- Replaces _G.Bodies with World.store pattern
World.store("Bodies", {})

-- System: Map Paddle Input to Box2D Velocity
local PaddleInput = System "paddle_input"
    :needs("paddle")
    :does(function(e, ctx)
        local body = World.store("Bodies")[e.id]
        if body and e.paddle.id == 1 then
            local vy = 0
            if love.keyboard.isDown("w") then vy = -500 end
            if love.keyboard.isDown("s") then vy = 500 end
            body:setLinearVelocity(0, vy)
        end
    end)

-- System: Sync Box2D results back to ECS Components
local SyncPhysics = System "sync"
    :needs("position", "physics")
    :does(function(e)
        local body = World.store("Bodies")[e.id]
        if body then
            local x, y = body:getPosition()
            e.position.x, e.position.y = x, y
        end
    end)

local Render = System "render"
    :needs("position", "size")
    :does(function(e)
        love.graphics.rectangle("fill", e.position.x - e.size.w/2, e.position.y - e.size.h/2, e.size.w, e.size.h)
    end)

local logic_sched = Scheduler.new()
    -- Register a global procedure (runs independently of entities)
    :register(function(ctx)
        world_box2d:update(ctx.dt)
    end)
    :register(PaddleInput)
    :register(SyncPhysics)

local draw_sched = Scheduler.new()
    :register(Render)

local function spawn_phys(x, y, w, h, p_type, is_ball)
    local id = World.spawn { position = {x=x, y=y}, size = {w=w, h=h} }
    World.add_component(id, "physics", {exists = 1})
    
    local body = lp.newBody(world_box2d, x, y, p_type)
    local shape = lp.newRectangleShape(w, h)
    local fixture = lp.newFixture(body, shape)
    
    if is_ball then
        fixture:setRestitution(1.05)
        fixture:setFriction(0)
        body:setLinearVelocity(300, 300)
    end
    
    World.store("Bodies")[id] = body
    return id
end

function love.load()
    lp.setMeter(64)
    -- Ball
    spawn_phys(400, 300, 16, 16, "dynamic", true)
    -- Player
    local p_id = spawn_phys(30, 300, 20, 100, "kinematic", false)
    World.add_component(p_id, "paddle", {id = 1})

    -- Screen Walls
    local top = lp.newBody(world_box2d, 400, -5, "static")
    lp.newFixture(top, lp.newRectangleShape(800, 10))
    local bot = lp.newBody(world_box2d, 400, 605, "static")
    lp.newFixture(bot, lp.newRectangleShape(800, 10))
    local right = lp.newBody(world_box2d, 805, 300, "static")
    lp.newFixture(right, lp.newRectangleShape(10, 600))
    local left = lp.newBody(world_box2d, -5, 300, "static")
    lp.newFixture(left, lp.newRectangleShape(10, 600))
end

function love.update(dt) logic_sched:tick(dt) end
function love.draw() draw_sched:tick(0) end