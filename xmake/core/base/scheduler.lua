--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
-- 
-- Copyright (C) 2015-2020, TBOOX Open Source Group.
--
-- @author      ruki
-- @file        scheduler.lua
--

-- define module: scheduler
local scheduler  = scheduler or {}
local _coroutine = _coroutine or {}

-- load modules
local table     = require("base/table")
local option    = require("base/option")
local string    = require("base/string")
local poller    = require("base/poller")
local timer     = require("base/timer")
local hashset   = require("base/hashset")
local coroutine = require("base/coroutine")
local bit       = require("bit")

-- new a coroutine instance
function _coroutine.new(name, thread)
    local instance   = table.inherit(_coroutine)
    instance._NAME   = name
    instance._THREAD = thread
    setmetatable(instance, _coroutine)
    return instance
end

-- get the coroutine name
function _coroutine:name()
    return self._NAME or "none"
end

-- set the coroutine name
function _coroutine:name_set(name)
    self._NAME = name
end

-- get the raw coroutine thread 
function _coroutine:thread()
    return self._THREAD
end

-- get the coroutine status
function _coroutine:status()
    return coroutine.status(self:thread())
end

-- is dead?
function _coroutine:is_dead()
    return self:status() == "dead"
end

-- is running?
function _coroutine:is_running()
    return self:status() == "running"
end

-- is suspended?
function _coroutine:is_suspended()
    return self:status() == "suspended"
end

-- get the current timer task
function _coroutine:_timer_task()
    return self._TIMER_TASK
end

-- set the timer task
function _coroutine:_timer_task_set(task)
    self._TIMER_TASK = task
end

-- tostring(coroutine)
function _coroutine:__tostring()
    return string.format("<co: %s/%s>", self:thread(), self:name())
end

-- gc(coroutine)
function _coroutine:__gc()
    self._THREAD = nil
end

-- get the timer of scheduler
function scheduler:_timer()
    local t = self._TIMER
    if t == nil then
        t = timer:new()
        self._TIMER = t
    end
    return t
end

-- get poller object data for socket, pipe or process object 
function scheduler:_poller_data(obj)
    return self._POLLERDATA and self._POLLERDATA[obj] or nil
end

-- set poller object data
--
-- data.co_recv:            the suspended coroutine for waiting poller/recv
-- data.co_send:            the suspended coroutine for waiting poller/send
-- data.poller_events_wait: the waited events for poller
-- data.poller_events_save: the saved events for poller (triggered)
--
function scheduler:_poller_data_set(obj, data)
    local pollerdata = self._POLLERDATA 
    if not pollerdata then
        pollerdata = {}
        self._POLLERDATA = pollerdata
    end
    pollerdata[obj] = data
end

-- resume the suspended coroutine after poller callback
function scheduler:_poller_resume_co(co, events)

    -- cancel timer task if exists
    local timer_task = co:_timer_task()
    if timer_task then
        timer_task.cancel = true
    end

    -- the scheduler has been stopped? mark events as error to stop the coroutine
    if not self._STARTED then
        events = poller.EV_POLLER_ERROR
    end

    -- this coroutine must be suspended
    assert(co:is_suspended())

    -- resume this coroutine task
    self:_co_tasks_suspended():remove(co)
    return self:co_resume(co, (bit.band(events, poller.EV_POLLER_ERROR) ~= 0) and -1 or events)
end

-- the poller events callback
function scheduler:_poller_events_cb(obj, events)

    -- get poller object data
    local pollerdata = self:_poller_data(obj)
    assert(pollerdata, string.format("%s: cannot get poller data!", obj))

    -- get poller object events
    local events_prev_wait = pollerdata.poller_events_wait
    local events_prev_save = pollerdata.poller_events_save

    -- eof for edge trigger?
    if bit.band(events, poller.EV_POLLER_EOF) ~= 0 then
        -- cache this eof as next recv/send event
        events = bit.band(events, bit.bnot(poller.EV_POLLER_EOF))
        events_prev_save = bit.bor(events_prev_save, events_prev_wait)
        pollerdata.poller_events_save = events_prev_save
    end

    -- get the waiting coroutines
    local co_recv = bit.band(events, poller.EV_POLLER_RECV) ~= 0 and pollerdata.co_recv or nil
    local co_send = bit.band(events, poller.EV_POLLER_SEND) ~= 0 and pollerdata.co_send or nil

    -- return the events result for the waiting coroutines
    if co_recv and co_recv == co_send then
        pollerdata.co_recv = nil
        pollerdata.co_send = nil
        return self:_poller_resume_co(co_recv, events)
    else 
    
        if co_recv then
            pollerdata.co_recv = nil
            local ok, errors = self:_poller_resume_co(co_recv, bit.band(events, bit.bnot(poller.EV_POLLER_SEND)))
            if not ok then
                return false, errors
            end
            events = bit.band(events, bit.bnot(poller.EV_POLLER_RECV))
        end
        if co_send then
            pollerdata.co_send = nil
            local ok, errors = self:_poller_resume_co(co_send, bit.band(events, bit.bnot(poller.EV_POLLER_RECV)))
            if not ok then
                return false, errors
            end
            events = bit.band(events, bit.bnot(poller.EV_POLLER_SEND))
        end

        -- no coroutines are waiting? cache this events
        if bit.band(events, poller.EV_POLLER_RECV) ~= 0 or bit.band(events, poller.EV_POLLER_SEND) ~= 0 then
            events_prev_save = bit.bor(events_prev_save, events)
            pollerdata.poller_events_save = events_prev_save
        end
    end
    return true
end

-- get all suspended coroutine tasks
function scheduler:_co_tasks_suspended()
    local co_tasks_suspended = self._CO_TASKS_SUSPENDED 
    if not co_tasks_suspended then
        co_tasks_suspended = hashset.new()
        self._CO_TASKS_SUSPENDED = co_tasks_suspended
    end
    return co_tasks_suspended
end

-- cancel and resume all suspended tasks after stopping scheduler
-- we cannot suspend them forever, all tasks will be exited directly and free all resources.
function scheduler:_co_tasks_suspended_cancel_all()
    for co in self:_co_tasks_suspended():keys() do
        local ok, errors = self:co_resume(co, -1) 
        if not ok then
            return false, errors
        end
    end
    return true
end

-- start a new coroutine task
function scheduler:co_start(cotask, ...)
    return self:co_start_named(nil, cotask, ...)
end

-- start a new named coroutine task
function scheduler:co_start_named(coname, cotask, ...)
    local co
    co = _coroutine.new(coname, coroutine.create(function(...) 
        cotask(...)
        self:co_tasks()[co:thread()] = nil
        if self:co_count() > 0 then
            self._CO_COUNT = self:co_count() - 1
        end
    end))
    self:co_tasks()[co:thread()] = co
    self._CO_COUNT = self:co_count() + 1
    if self._STARTED then
        local ok, errors = self:co_resume(co, ...)
        if not ok then
            return nil, errors
        end
    else
        self._CO_READY_TASKS = self._CO_READY_TASKS or {}
        table.insert(self._CO_READY_TASKS, {co, table.pack(...)})
    end
    return co
end

-- resume the given coroutine
function scheduler:co_resume(co, ...)
    return coroutine.resume(co:thread(), ...)
end

-- suspend the current coroutine
function scheduler:co_suspend(...)
    return coroutine.yield(...)
end

-- get the current running coroutine 
function scheduler:co_running()
    local running = coroutine.running()
    return running and self:co_tasks()[running] or nil 
end

-- get all coroutine tasks
function scheduler:co_tasks()
    local cotasks = self._CO_TASKS
    if not cotasks then
        cotasks = {}
        self._CO_TASKS = cotasks
    end
    return cotasks
end

-- get all coroutine count
function scheduler:co_count()
    return self._CO_COUNT or 0
end

-- wait poller object io events, only for socket and pipe object
function scheduler:poller_wait(obj, events, timeout)

    -- get the running coroutine
    local running = self:co_running()
    if not running then
        return -1, "we must call poller_wait() in coroutine with scheduler!"
    end

    -- is stopped?
    if not self._STARTED then
        return -1, "the scheduler is stopped!"
    end

    -- check the object type
    local otype = obj:otype()
    if otype ~= poller.OT_SOCK and otype ~= poller.OT_PIPE then
        return -1, string.format("%s: invalid object type(%d)!", obj, otype)
    end

    -- get and allocate poller object data
    local pollerdata = self:_poller_data(obj)
    if not pollerdata then
        pollerdata = {poller_events_wait = 0, poller_events_save = 0}
        self:_poller_data_set(obj, pollerdata)
    end

    -- enable edge-trigger mode if be supported
    if otype == poller.OT_SOCK and self._SUPPORT_EV_POLLER_CLEAR then
        events = bit.bor(events, poller.EV_POLLER_CLEAR)
    end

    -- get the previous poller object events
    local events_wait = events
    if pollerdata.poller_events_wait ~= 0 then
        
        -- return the cached events directly if the waiting events exists cache
        local events_prev_wait = pollerdata.poller_events_wait
        local events_prev_save = pollerdata.poller_events_save
        if events_prev_save ~= 0 and bit.band(events_prev_wait, events) ~= 0 then

            -- check error?
            if bit.band(events_prev_save, poller.EV_POLLER_ERROR) ~= 0 then
                pollerdata.poller_events_save = 0
                return -1, string.format("%s: events error!", obj)
            end

            -- clear cache events
            pollerdata.poller_events_save = bit.band(events_prev_save, bit.bnot(events))

            -- return the cached events
            return bit.band(events_prev_save, events)
        end

        -- modify the wait events and reserve the pending events in other coroutine
        events_wait = events_prev_wait
        if bit.band(events_wait, poller.EV_POLLER_RECV) ~= 0 and not pollerdata.co_recv then
            events_wait = bit.band(events_wait, bit.bnot(poller.EV_POLLER_RECV))
        end
        if bit.band(events_wait, poller.EV_POLLER_SEND) ~= 0 and not pollerdata.co_send then
            events_wait = bit.band(events_wait, bit.bnot(poller.EV_POLLER_SEND))
        end
        events_wait = bit.bor(events_wait, events)

        -- modify poller object from poller for waiting events if the waiting events has been changed 
        if bit.band(events_prev_wait, events_wait) ~= events_wait then

            -- maybe wait recv/send at same time
            local ok, errors = poller:modify(obj, events_wait, self._poller_events_cb)
            if not ok then
                return -1, errors
            end
        end
    else

        -- insert poller object events
        local ok, errors = poller:insert(obj, events_wait, self._poller_events_cb)
        if not ok then
            return -1, errors
        end
    end

    -- register timeout task to timer
    local timer_task = nil
    if timeout > 0 then
        timer_task = self:_timer():post(function (cancel) 
            if not cancel and running:is_suspended() then
                self:_co_tasks_suspended():remove(running)
                self:co_resume(running, 0)
            end
        end, timeout)
    end
    running:_timer_task_set(timer_task)

    -- save waiting events 
    pollerdata.poller_events_wait = events_wait
    pollerdata.poller_events_save = 0

    -- save the current coroutine 
    if bit.band(events, poller.EV_POLLER_RECV) ~= 0 then
        pollerdata.co_recv = running
    end
    if bit.band(events, poller.EV_POLLER_SEND) ~= 0 then
        pollerdata.co_send = running
    end

    -- save the suspended coroutine
    self:_co_tasks_suspended():insert(running)

    -- wait
    return self:co_suspend()
end

-- cancel poller object events
function scheduler:poller_cancel(obj)

    -- reset the pollerdata data
    local pollerdata = self:_poller_data(obj)
    if pollerdata then
        if pollerdata.poller_events_wait ~= 0 then
            local ok, errors = poller:remove(obj)
            if not ok then
                return false, errors
            end
        end
        self:_poller_data_set(obj, nil)
    end
    return true
end

-- sleep some times (ms)
function scheduler:sleep(ms)

    -- we need not do sleep 
    if ms == 0 then
        return true
    end

    -- get the running coroutine
    local running = self:co_running()
    if not running then
        return false, "we must call sleep() in coroutine with scheduler!"
    end

    -- is stopped?
    if not self._STARTED then
        return false, "the scheduler is stopped!"
    end

    -- register timeout task to timer
    self:_timer():post(function (cancel) 
        if running:is_suspended() then
            self:co_resume(running)
        end
    end, ms)

    -- wait
    self:co_suspend()
    return true
end

-- stop the scheduler loop
function scheduler:stop()
    -- mark scheduler status as stopped and spank the poller:wait()
    self._STARTED = false
    poller:spank()
    return true
end

-- run loop, schedule coroutine with socket/io and sub-processes
function scheduler:runloop()

    -- start loop
    self._STARTED = true

    -- ensure poller has been initialized first (for windows/iocp) and check edge-trigger mode (for epoll/kqueue)
    if poller:support(poller.OT_SOCK, poller.EV_POLLER_CLEAR) then
        self._SUPPORT_EV_POLLER_CLEAR = true
    end

    -- start all ready coroutine tasks
    local co_ready_tasks = self._CO_READY_TASKS
    if co_ready_tasks then
        for _, task in pairs(co_ready_tasks) do
            local co   = task[1]
            local argv = task[2]
            local ok, errors = self:co_resume(co, table.unpack(argv))
            if not ok then
                return false, errors
            end
        end
    end
    self._CO_READY_TASKS = nil

    -- run loop
    opt = opt or {}
    local ok = true
    local errors = nil
    local timeout = -1
    while self._STARTED and self:co_count() > 0 do 

        -- get the next timeout
        timeout = self:_timer():delay() or 1000

        -- wait events
        local count, events = poller:wait(timeout)
        if count < 0 then
            ok = false
            errors = events
            break
        end

        -- resume all suspended tasks with events
        for _, e in ipairs(events) do
            local obj       = e[1]
            local objevents = e[2]
            local eventfunc = e[3]
            if eventfunc then
                ok, errors = eventfunc(self, obj, objevents)
                if not ok then
                    break
                end
            end
        end
        if not ok then
            break
        end

        -- spank the timer and trigger all timeout tasks
        self:_timer():next()
    end

    -- mark the loop as stopped first
    self._STARTED = false

    -- cancel all suspended tasks after stopping scheduler
    local ok2, errors2 = self:_co_tasks_suspended_cancel_all()
    if ok and not ok2 then
        ok = ok2
        errors = errors2
    end

    -- cancel all timeout tasks and trigger them
    self:_timer():kill()

    -- finished
    return ok, errors
end

-- return module: scheduler
return scheduler