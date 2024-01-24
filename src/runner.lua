#!lua name=runner

-- the sp module. sp functions and internal state
local sp = {}

-- list of resources for reading/writing.
-- named r to make guards shorter...
local r = {}

-- set up all operations etc in this function.
local function init()
   -- setup initial states if the resources are not on redis already
   r.scratch = r.scratch or { counter = 0 }
   r.atr1 = r.atr1 or
      {
         position = "waiting",
         has_kit = true,
      }
   r.atr2 = r.atr2 or
      {
         position = "pou",
         has_kit = true,
      }
   r.atr3 = r.atr3 or
      {
         position = "kitting",
         has_kit = false,
      }
   r.roles = r.roles or
      {
         waiting = "atr1",
         pou = "atr2",
         kitting = "atr3",
      }

   -- control logic

   -- We can have operations as well as plain functions.
   sp.add_function("counter",
                   function()
                      r.scratch.counter = r.scratch.counter + 1
                   end
   )

   -- For demonstration operations just sleep a bit before finishing.
   local dummy_time = 5000

   -- helpers
   local function swap_roles()
      r.roles = {
         kitting = r.roles.pou,
         pou = r.roles.waiting,
         waiting = r.roles.kitting
      }
   end

   -- Main control code. Straight port of coordinator.rs. No blocking stuff.
   sp.add_function("controller",
                   function()
                      local kitting = r[r.roles.kitting] -- pointers
                      local waiting = r[r.roles.waiting]
                      local pou = r[r.roles.pou]

                      if not kitting.operation and kitting.position ~= "kitting" then
                         local op_name = r.roles.kitting .. "_goto_kitting"
                         sp.add_operation {
                            name = op_name,

                            -- guard includes waitings position.
                            start_guard = function (state) return waiting.position == "wp18" end,
                            start_action = function (state)
                               state.started_at = sp.now
                               kitting.operation = op_name
                            end,

                            -- pretend to finish after some time
                            finish_guard = function (state) return sp.now > state.started_at + dummy_time end,
                            finish_action = function (state)
                               kitting.operation = nil
                               kitting.position = "kitting"
                               -- remove this operation, we recreate it when we want to run it.
                               sp.remove_operation(op_name)
                            end,
                         }
                      end

                      if not kitting.operation and kitting.position == "kitting" and not kitting.has_kit then
                         local op_name = r.roles.kitting .. "_kitting_ack"
                         sp.add_operation {
                            name = op_name,

                            start_guard = function (state) return true end,
                            start_action = function (state)
                               state.started_at = sp.now
                               kitting.operation = op_name
                            end,

                            finish_guard = function (state) return sp.now > state.started_at + dummy_time end,
                            finish_action = function (state)
                               kitting.operation = nil
                               kitting.has_kit = true
                               sp.remove_operation(op_name)
                            end,
                         }
                      end

                      if not waiting.operation
                         and waiting.position ~= "wp18"
                         and waiting.position ~= "waiting" then
                         local op_name = r.roles.waiting .. "_goto_wp18"
                         sp.add_operation {
                            name = op_name,

                            start_guard = function (state) return true end,
                            start_action = function (state)
                               state.started_at = sp.now
                               waiting.operation = op_name
                            end,

                            finish_guard = function (state) return sp.now > state.started_at + dummy_time end,
                            finish_action = function (state)
                               waiting.operation = nil
                               waiting.position = "wp18"
                               -- remove this operation, we recreate it when we want to run it.
                               sp.remove_operation(op_name)
                            end,
                         }
                      end

                      if not waiting.operation
                         and waiting.position == "wp18" then
                         local op_name = r.roles.waiting .. "_goto_waiting"
                         sp.add_operation {
                            name = op_name,

                            -- guard includes kitting position. check
                            -- wp17 etc... for simplicity here we
                            -- check that kitting has moved all the
                            -- way to the kitting wp
                            start_guard = function (state) return kitting.position == "kitting" end,
                            start_action = function (state)
                               state.started_at = sp.now
                               waiting.operation = op_name
                            end,

                            finish_guard = function (state) return sp.now > state.started_at + dummy_time end,
                            finish_action = function (state)
                               waiting.operation = nil
                               waiting.position = "waiting"
                               -- remove this operation, we recreate it when we want to run it.
                               sp.remove_operation(op_name)
                            end,
                         }
                      end

                      if not pou.operation then
                         local op_name = r.roles.pou .. "_pou_ack"
                         sp.add_operation {
                            name = op_name,

                            start_guard = function (state) return true end,
                            start_action = function (state)
                               state.started_at = sp.now
                               pou.operation = op_name
                            end,

                            finish_guard = function (state) return kitting.has_kit and sp.now > state.started_at + dummy_time end,
                            finish_action = function (state)
                               pou.operation = nil
                               pou.has_kit = false -- remove the kit.
                               -- remove this operation, we recreate it when we want to run it.
                               sp.remove_operation(op_name)

                               -- when we finish we also want to swap the roles.
                               swap_roles()
                            end,
                         }
                      end
                   end
   )
end

--
-- Below is the SP runner code. Should not be changed.
--

function sp.get_redis_state()
   for key, data in pairs(r or {}) do
      local upd_data = sp.get_redis_json(key, data)
      r[key] = data
   end

   -- read operation state
   local op_states = sp.get_redis_json('sp/operations')
   for op_name, op_state in pairs(op_states) do
      if sp.operations and sp.operations[op_name] then
            sp.operations[op_name].state = op_state
      end
   end
end

function sp.set_redis_state()
   for key, data in pairs(r or {}) do
      sp.set_redis_json(key, data)
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

   -- run functions
   for _, f in pairs(sp.functions or {}) do
      f()
   end

   -- run operations
   for name, o in pairs(sp.operations or {}) do
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

function sp.add_function(name, f)
   sp.functions = sp.functions or {}
   sp.functions[name] = f
end

function sp.add_operation(o)
   local o = o or {}
   o.state = { state = "i" }
   o.start_guard = o.start_guard or function (state) return false end
   o.start_action = o.start_action or function (state) end

   o.finish_guard = o.finish_guard or function (state) return true end
   o.finish_action = o.finish_action or function (state) end

   o.reset_guard = o.reset_guard or function (state) return false end
   o.reset_action = o.reset_action or function (state) end

   sp.operations = sp.operations or {}
   sp.operations[o.name] = o
end

function sp.remove_operation(name)
   sp.operations[name] = nil
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
