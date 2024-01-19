#!lua name=runner

-- the sp module. sp functions and internal state
local sp = {}

-- list of resources for reading/writing.
-- named r to make guards shorter...
local r = {}

-- set up all operations etc in this function.
local function init()
   -- setup resources (for json get/set)
   sp.resources = { "robot1", "robot2", "scratch" }

   -- setup initial states if the resources are not on redis already
   r.robot1 = { active = false }
   r.scratch = { counter = 0 }

   -- add operations
   sp.add_operation {
      name = "r1_op1",

      -- can always start
      start_guard = function (state) return not r.robot1.active end,
      start_action = function (state)
         r.robot1.active = true
         state.started_at = sp.now
      end,

      -- finishes after five seconds.
      finish_guard = function (state) return sp.now > state.started_at + 5000 end,
      finish_action = function (state)
         state.result = "success"
         state.started_at = nil
      end,

      -- reset action
      reset_guard = function (state) return true end,
      reset_action = function (state)
         state.result = nil
      end
   }

   -- Only has a start transition, not an operation.
   sp.add_operation {
      name = "counter",

      -- can always start
      start_guard = function (state) return true end,
      start_action = function (state)
         r.scratch.counter = r.scratch.counter + 1
      end,
   }
end

--
-- Below is the SP runner code. Should not be changed.
--

function sp.get_redis_state()
   for _, key in ipairs(sp.resources or {}) do
      local data = sp.get_redis_json(key)
      r[key] = data
   end

   -- read operation state
   local op_states = sp.get_redis_json('sp/operations')
   for op_name, op_state in pairs(op_states) do
      if sp.operations[op_name] ~= nil then
            sp.operations[op_name].state = op_state
      end
   end
end

function sp.set_redis_state()
   for _, key in ipairs(sp.resources or {}) do
      sp.set_redis_json(key, r[key])
   end

   -- write sp internal state
   sp.set_redis_json('sp/now', sp.now)

   -- write operation state
   local op_states = {}
   for n, e in pairs(sp.operations) do
      op_states[n] = e.state
   end
   sp.set_redis_json('sp/operations', op_states)
end

function sp.tick()
   -- if not initialized, perform init
   if sp.operations == nil then
      init()
   end

   local time = redis.call('TIME')
   -- convert redis time to milliseconds.
   sp.now = time[1] * 1000 + math.floor(time[2] / 1000)

   sp.get_redis_state()

   local fired = sp.take_transitions()
   if #fired > 0 then
      local info = {
         fired = fired,
         time = sp.now,
      }
      redis.call('lpush', 'sp/fired', cjson.encode(info))
      redis.call('ltrim', 'sp/fired', 0, 999)
   end

   sp.set_redis_state()

   return #fired
end

sp.take_transitions = function ()
   local fired = {}
   for name, o in pairs(sp.operations) do
      if o.state.state == "i" and o.start_guard(o.state) then
         o.state.state = "e"
         o.start_action(o.state)
         table.insert(fired, "start_" .. name)
      elseif o.state.state == "e" and o.finish_guard(o.state) then
         o.state.state = "f"
         o.finish_action(o.state)
         table.insert(fired, "finish_" .. name)
      elseif o.state.state == "f" and o.reset_guard(o.state) then
         o.state.state = "i"
         o.reset_action(o.state)
         table.insert(fired, "reset_" .. name)
      end
   end

   return fired
end

sp.add_operation = function (o)
   local o = o or {}
   o.state = { state = "i" }
   o.start_guard = o.start_guard or function (state) return false end
   o.start_action = o.start_action or function (state) end

   o.finish_guard = o.finish_guard or function (state) return true end
   o.finish_action = o.finish_action or function (state) end

   o.reset_guard = o.reset_guard or function (state) return true end
   o.reset_action = o.reset_action or function (state) end

   sp.operations = sp.operations or {}
   sp.operations[o.name] = o
end

sp.get_redis_json = function(key, default)
   local val = redis.call('get', key)
   if val then
      val = cjson.decode(val)
      return val or (default or {})
   end
   return (default or {})
end

sp.set_redis_json = function(key, value)
   redis.call('set', key, cjson.encode(value))
end

redis.register_function('tick', sp.tick)
