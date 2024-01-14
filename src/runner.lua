#!lua name=runner

-- define our resources
local robot1 = {}
local robot2 = {}
-- and scratch space for local sp variables
local scratch = {counter = 0}

-- define transitions
local transitions = {
   {
      name = "r1_activate",
      guard = function () return not robot1.active and not robot2.active end,
      action = function ()
         robot1.active = true
         scratch.counter = scratch.counter + 1 -- count the complete cycles.
      end
   },
   {
      name = "r1_deactivate",
      guard = function () return robot1.active and robot2.active end,
      action = function () robot1.active = false end,
   },
   {
      name = "r2_activate",
      guard = function () return not robot2.active and robot1.active end,
      action = function () robot2.active = true end,
   },
   {
      name = "r2_deactivate",
      guard = function () return robot2.active and not robot1.active end,
      action = function () robot2.active = false end,
   },
}

local function take_transition()
   for i, t in ipairs(transitions) do
      if t.guard() then
         t.action()
         return t.name
      end
   end
   return nil
end

local function get_redis_json(key, default)
   local val = redis.call('get', key)
   if val then
      val = cjson.decode(val)
      return val or (default or {})
   end
   return (default or {})
end

local function get_redis_state()
   robot1 = get_redis_json('robot1')
   robot2 = get_redis_json('robot2')
   scratch = get_redis_json('sp/scratch', scratch)
end

local function set_redis_state()
   redis.call('set', 'robot1', cjson.encode(robot1))
   redis.call('set', 'robot2', cjson.encode(robot2))
   redis.call('set', 'sp/scratch', cjson.encode(scratch))
end

local function tick()
   local start = redis.call('TIME')

   get_redis_state()

   local fired = take_transition()
   if fired then
      redis.call('lpush', 'sp/fired', fired)
      redis.call('ltrim', 'sp/fired', 0, 999)
   end

   set_redis_state()

   local finish = redis.call('TIME')
   -- due to this change, measuring time currently does not work.
   -- https://github.com/redis/redis/issues/12699
   local finish = (finish[1]-start[1])*1000000+(finish[2]-start[2])
   return { fired, finish }
end

redis.register_function('tick', tick)
redis.register_function('get_redis_state', get_redis_state)
redis.register_function('set_redis_state', set_redis_state)
