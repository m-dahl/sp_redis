#!lua name=runner

-- the sp module. sp functions and internal state
local sp = {
   is_init = false,
}

-- list of resources for reading/writing.
-- named r to make guards shorter...
local r = {}

-- some random definitions we need
-- redefines some agv positions from ARIAC to axelline
local location_to_name = {
   [0] = 'pou',      -- conveyor
   [1] = 'waiting',  -- station 1
   [2] = 'wp18',     -- station 2
   [3] = 'kitting',  -- depot
   [99] = 'unknown', -- moving
}

local atr_to_agv = {
   atr1 = 'agv1',
   atr2 = 'agv2',
   atr3 = 'agv3',
}

local agv_to_atr = {
   agv1 = 'atr1',
   agv2 = 'atr2',
   agv3 = 'atr3',
}

local function table_invert(t)
   local s={}
   for k,v in pairs(t) do
     s[v]=k
   end
   return s
end

local name_to_location = {}

-- helper functions
local function kitting()
   return r[r.roles.kitting]
end

local function waiting()
   return r[r.roles.waiting]
end

local function pou()
   return r[r.roles.pou]
end

-- set up all operations etc in this function.
local function init()
   name_to_location = table_invert(location_to_name)

   -- setup initial states if the resources are not on redis already

   r.scratch = { counter = 0 }
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

   -- inputs
   r['agv1/state'] = {}
   r['agv2/state'] = {}
   r['agv3/state'] = {}

   -- control logic

   -- We can have operations as well as plain functions.
   sp.add_function("counter",
                   function()
                      r.scratch.counter = (r.scratch.counter or 0) + 1
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

   local function get_location(agv)
      local as_string = location_to_name[r[agv].location]
      return as_string
   end

   -- Main control code. Straight port of coordinator.rs. No blocking stuff.
   sp.add_function("controller",
                   function()
                      if not kitting().operation and kitting().position ~= "kitting" then
                         local op_name = r.roles.kitting .. "_goto_kitting"
                         sp.add_operation {
                            name = op_name,

                            -- guard includes waitings position.
                            start_guard = function (state) return waiting().position == "wp18" end,
                            start_action = function (state)
                               state.started_at = sp.now

                               local ariac_agv_name = atr_to_agv[r.roles.kitting]
                               local key = ariac_agv_name .. "/goal"
                               local value = name_to_location['kitting']
                               r[key] = value

                               kitting().operation = op_name
                            end,

                            -- pretend to finish after some time
                            finish_guard = function (state)
                               local ariac_agv_name = atr_to_agv[r.roles.kitting]
                               local key = ariac_agv_name .. "/state"
                               local loc = r[key].location
                               return location_to_name[loc] == 'kitting'
                            end,
                            finish_action = function (state)
                               kitting().operation = nil
                               kitting().position = "kitting"
                               -- remove this operation, we recreate it when we want to run it.
                               sp.remove_operation(op_name)
                            end,
                         }
                      end

                      if not kitting().operation and kitting().position == "kitting" and not kitting().has_kit then
                         local op_name = r.roles.kitting .. "_kitting_ack"
                         sp.add_operation {
                            name = op_name,

                            start_guard = function (state) return true end,
                            start_action = function (state)
                               state.started_at = sp.now
                               kitting().operation = op_name
                            end,

                            finish_guard = function (state) return sp.now > state.started_at + dummy_time end,
                            finish_action = function (state)
                               kitting().operation = nil
                               kitting().has_kit = true

                               sp.remove_operation(op_name)
                            end,
                         }
                      end

                      if not waiting().operation
                         and waiting().position ~= "wp18"
                         and waiting().position ~= "waiting" then
                         local op_name = r.roles.waiting .. "_goto_wp18"
                         sp.add_operation {
                            name = op_name,

                            start_guard = function (state) return true end,
                            start_action = function (state)
                               state.started_at = sp.now

                               local ariac_agv_name = atr_to_agv[r.roles.waiting]
                               local key = ariac_agv_name .. "/goal"
                               local value = name_to_location['wp18']
                               r[key] = value

                               waiting().operation = op_name
                            end,

                            finish_guard = function (state)
                               local ariac_agv_name = atr_to_agv[r.roles.waiting]
                               local key = ariac_agv_name .. "/state"
                               local loc = r[key].location
                               return location_to_name[loc] == 'wp18'
                            end,
                            finish_action = function (state)
                               waiting().operation = nil
                               waiting().position = "wp18"
                               -- remove this operation, we recreate it when we want to run it.
                               sp.remove_operation(op_name)
                            end,
                         }
                      end

                      if not waiting().operation
                         and waiting().position == "wp18" then
                         local op_name = r.roles.waiting .. "_goto_waiting"
                         sp.add_operation {
                            name = op_name,

                            -- guard includes kitting position. check
                            -- wp17 etc... for simplicity here we
                            -- check that kitting has moved all the
                            -- way to the kitting wp
                            start_guard = function (state) return kitting().position == "kitting" end,
                            start_action = function (state)
                               state.started_at = sp.now

                               local ariac_agv_name = atr_to_agv[r.roles.waiting]
                               local key = ariac_agv_name .. "/goal"
                               local value = name_to_location['waiting']
                               r[key] = value

                               waiting().operation = op_name
                            end,

                            finish_guard = function (state)
                               local ariac_agv_name = atr_to_agv[r.roles.waiting]
                               local key = ariac_agv_name .. "/state"
                               local loc = r[key].location
                               return location_to_name[loc] == 'waiting'
                            end,
                            finish_action = function (state)
                               waiting().operation = nil
                               waiting().position = "waiting"
                               -- remove this operation, we recreate it when we want to run it.
                               sp.remove_operation(op_name)
                            end,
                         }
                      end

                      if not pou().operation then
                         local op_name = r.roles.pou .. "_pou_ack"
                         sp.add_operation {
                            name = op_name,

                            start_guard = function (state) return true end,
                            start_action = function (state)
                               state.started_at = sp.now
                               pou().operation = op_name
                            end,

                            finish_guard = function (state) return waiting().position == "waiting" and kitting().has_kit and sp.now > state.started_at + dummy_time end,
                            finish_action = function (state)
                               pou().operation = nil
                               pou().has_kit = false -- remove the kit.
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
   local json_errors = {}
   for key, data in pairs(r or {}) do
      local upd_data = sp.get_redis_json(key, data, json_errors)
      r[key] = upd_data
   end

   -- read operation state
   local op_states = sp.get_redis_json('sp/operations', {}, json_errors)
   for op_name, op_state in pairs(op_states) do
      if sp.operations and sp.operations[op_name] then
            sp.operations[op_name].state = op_state
      end
   end

   return json_errors
end

function sp.set_redis_state()
   for key, data in pairs(r or {}) do
      sp.set_redis_json(key, data)
   end

   -- write sp internal state
   sp.set_redis_json('sp/is_init', sp.is_init)
   sp.set_redis_json('sp/now', sp.now)

   -- write operation state
   local op_states = {}
   for n, e in pairs(sp.operations or {}) do
      op_states[n] = e.state
   end
   sp.set_redis_json('sp/operations', op_states)
end

function sp.tick()
   local json_errors = {}
   -- if not initialized, perform init
   if not sp.is_init then
      r = {} -- reset resource states.
      init()
      sp.is_init = true
   else
      -- else we are continuing execution, get the persisted state
      json_errors = sp.get_redis_state()
   end

   local time = redis.call('TIME')
   -- convert redis time to milliseconds.
   sp.now = time[1] * 1000 + math.floor(time[2] / 1000)


   local fired, errors = sp.take_transitions()
   if #fired > 0 then
      local info = {
         fired = fired,
         time = sp.now,
      }
      redis.call('lpush', 'sp/fired', cjson.encode(info))
      redis.call('ltrim', 'sp/fired', 0, 999)
   end

   if #errors > 0 then
      local info = {
         errors = errors,
         time = sp.now,
      }
      redis.call('lpush', 'sp/errors', cjson.encode(info))
      redis.call('ltrim', 'sp/errors', 0, 999)
   end

   if #json_errors > 0 then
      local info = {
         errors = json_errors,
         time = sp.now,
      }
      redis.call('lpush', 'sp/json_errors', cjson.encode(info))
      redis.call('ltrim', 'sp/json_errors', 0, 999)
   end

   sp.set_redis_state()

   return #fired
end

sp.take_transitions = function ()
   local fired = {}
   local errors = {}

   -- run functions
   for _, f in pairs(sp.functions or {}) do
      f()
   end

   -- run operations
   for name, o in pairs(sp.operations or {}) do
      if o.state.state == "i" then
         local status, result_or_error = pcall(o.start_guard, o.state)
         if status and result_or_error then
            o.state.state = "e"
            o.start_action(o.state)
            table.insert(fired, "start_" .. name)
         elseif not status then
            table.insert(errors, "start_" .. name .. ": " .. result_or_error)
         end
      elseif o.state.state == "e" then
         local status, result_or_error = pcall(o.finish_guard, o.state)
         if status and result_or_error then
            o.state.state = "f"
            o.finish_action(o.state)
            table.insert(fired, "finish_" .. name)
         elseif not status then
            table.insert(errors, "finish_" .. name .. ": " .. result_or_error)
         end
      elseif o.state.state == "f" then
         local status, result_or_error = pcall(o.reset_guard, o.state)
         if status and result_or_error then
            o.state.state = "i"
            o.reset_action(o.state)
            table.insert(fired, "reset_" .. name)
         elseif not status then
            table.insert(errors, "reset_" .. name .. ": " .. result_or_error)
         end
      end
   end

   return fired, errors
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

sp.get_redis_json = function(key, default, json_errors)
   local val = redis.call('get', key)
   if val then
      local status, val_or_error = pcall(cjson.decode, val)
      if not status then
         table.insert(json_errors, "json error for key " .. key .. ": " .. val_or_error)
         return default or {}
      end
      return val_or_error or (default or {})
   end
   return (default or {})
end

sp.set_redis_json = function(key, value)
   redis.call('set', key, cjson.encode(value))
end

redis.register_function('tick', sp.tick)
