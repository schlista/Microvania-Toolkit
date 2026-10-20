-- mvtk/enemies/ai/behavior_tree.lua
-- ============================================================================
-- Behavior Tree Framework - Composable AI System
-- ============================================================================
-- Provides a flexible, composable behavior tree system for enemy AI.
-- Supports composite nodes (sequence, selector, parallel), decorators,
-- and leaf nodes (conditions, actions).
--
-- Usage:
--   local BT = require "mvtk.enemies.ai.behavior_tree"
--
--   local tree = BT.selector({
--       BT.sequence({
--           BT.condition("player_in_range"),
--           BT.condition("has_ammo"),
--           BT.action("shoot_at_player")
--       }),
--       BT.action("patrol")
--   })
--
--   -- In update:
--   tree:run(self, dt)

local M = {}

-- Node status constants
M.STATUS = {
    SUCCESS = "success",
    FAILURE = "failure",
    RUNNING = "running"
}

-- ============================================================================
-- BASE NODE
-- ============================================================================

local Node = {}
Node.__index = Node

function Node.new(node_type)
    local self = setmetatable({}, Node)
    self.node_type = node_type
    self.children = {}
    return self
end

function Node:run(context, dt)
    return M.STATUS.FAILURE
end

function Node:reset()
    for _, child in ipairs(self.children) do
        if child.reset then child:reset() end
    end
end

-- ============================================================================
-- COMPOSITE NODES
-- ============================================================================

--- Sequence: Runs children in order until one fails
-- Returns SUCCESS if all children succeed
-- Returns FAILURE if any child fails
-- Returns RUNNING if a child is still running
local Sequence = setmetatable({}, {__index = Node})
Sequence.__index = Sequence

function Sequence.new(children)
    local self = setmetatable(Node.new("sequence"), Sequence)
    self.children = children or {}
    self.current_index = 1
    return self
end

function Sequence:run(context, dt)
    while self.current_index <= #self.children do
        local child = self.children[self.current_index]
        local status = child:run(context, dt)

        if status == M.STATUS.RUNNING then
            return M.STATUS.RUNNING
        elseif status == M.STATUS.FAILURE then
            self.current_index = 1
            return M.STATUS.FAILURE
        end

        -- SUCCESS - move to next child
        self.current_index = self.current_index + 1
    end

    self.current_index = 1
    return M.STATUS.SUCCESS
end

function Sequence:reset()
    self.current_index = 1
    Node.reset(self)
end

--- Selector: Runs children until one succeeds
-- Returns SUCCESS if any child succeeds
-- Returns FAILURE if all children fail
-- Returns RUNNING if a child is still running
local Selector = setmetatable({}, {__index = Node})
Selector.__index = Selector

function Selector.new(children)
    local self = setmetatable(Node.new("selector"), Selector)
    self.children = children or {}
    self.current_index = 1
    return self
end

function Selector:run(context, dt)
    while self.current_index <= #self.children do
        local child = self.children[self.current_index]
        local status = child:run(context, dt)

        if status == M.STATUS.RUNNING then
            return M.STATUS.RUNNING
        elseif status == M.STATUS.SUCCESS then
            self.current_index = 1
            return M.STATUS.SUCCESS
        end

        -- FAILURE - try next child
        self.current_index = self.current_index + 1
    end

    self.current_index = 1
    return M.STATUS.FAILURE
end

function Selector:reset()
    self.current_index = 1
    Node.reset(self)
end

--- Parallel: Runs all children simultaneously
-- policy = "require_all" - SUCCESS when all succeed, FAILURE when any fails
-- policy = "require_one" - SUCCESS when any succeeds, FAILURE when all fail
local Parallel = setmetatable({}, {__index = Node})
Parallel.__index = Parallel

function Parallel.new(children, policy)
    local self = setmetatable(Node.new("parallel"), Parallel)
    self.children = children or {}
    self.policy = policy or "require_all"
    return self
end

function Parallel:run(context, dt)
    local success_count = 0
    local failure_count = 0
    local running_count = 0

    for _, child in ipairs(self.children) do
        local status = child:run(context, dt)
        if status == M.STATUS.SUCCESS then
            success_count = success_count + 1
        elseif status == M.STATUS.FAILURE then
            failure_count = failure_count + 1
        else
            running_count = running_count + 1
        end
    end

    if self.policy == "require_all" then
        if failure_count > 0 then
            return M.STATUS.FAILURE
        elseif running_count > 0 then
            return M.STATUS.RUNNING
        else
            return M.STATUS.SUCCESS
        end
    else -- require_one
        if success_count > 0 then
            return M.STATUS.SUCCESS
        elseif running_count > 0 then
            return M.STATUS.RUNNING
        else
            return M.STATUS.FAILURE
        end
    end
end

--- RandomSelector: Randomly picks a child to run
local RandomSelector = setmetatable({}, {__index = Node})
RandomSelector.__index = RandomSelector

function RandomSelector.new(children, weights)
    local self = setmetatable(Node.new("random_selector"), RandomSelector)
    self.children = children or {}
    self.weights = weights or {}
    self.selected_index = nil
    return self
end

function RandomSelector:run(context, dt)
    if not self.selected_index then
        -- Select a random child based on weights
        if #self.weights > 0 then
            local total = 0
            for _, w in ipairs(self.weights) do
                total = total + w
            end
            local roll = math.random() * total
            local cumulative = 0
            for i, w in ipairs(self.weights) do
                cumulative = cumulative + w
                if roll <= cumulative then
                    self.selected_index = i
                    break
                end
            end
        else
            self.selected_index = math.random(1, #self.children)
        end
    end

    local child = self.children[self.selected_index]
    local status = child:run(context, dt)

    if status ~= M.STATUS.RUNNING then
        self.selected_index = nil
    end

    return status
end

function RandomSelector:reset()
    self.selected_index = nil
    Node.reset(self)
end

-- ============================================================================
-- DECORATOR NODES
-- ============================================================================

--- Inverter: Inverts child result (SUCCESS <-> FAILURE)
local Inverter = setmetatable({}, {__index = Node})
Inverter.__index = Inverter

function Inverter.new(child)
    local self = setmetatable(Node.new("inverter"), Inverter)
    self.child = child
    return self
end

function Inverter:run(context, dt)
    local status = self.child:run(context, dt)
    if status == M.STATUS.SUCCESS then
        return M.STATUS.FAILURE
    elseif status == M.STATUS.FAILURE then
        return M.STATUS.SUCCESS
    end
    return M.STATUS.RUNNING
end

--- Repeater: Repeats child N times or until failure
local Repeater = setmetatable({}, {__index = Node})
Repeater.__index = Repeater

function Repeater.new(child, times)
    local self = setmetatable(Node.new("repeater"), Repeater)
    self.child = child
    self.times = times or -1  -- -1 = infinite
    self.current_count = 0
    return self
end

function Repeater:run(context, dt)
    local status = self.child:run(context, dt)

    if status == M.STATUS.RUNNING then
        return M.STATUS.RUNNING
    end

    if status == M.STATUS.FAILURE then
        self.current_count = 0
        return M.STATUS.FAILURE
    end

    self.current_count = self.current_count + 1

    if self.times > 0 and self.current_count >= self.times then
        self.current_count = 0
        return M.STATUS.SUCCESS
    end

    self.child:reset()
    return M.STATUS.RUNNING
end

function Repeater:reset()
    self.current_count = 0
    if self.child.reset then self.child:reset() end
end

--- Succeeder: Always returns SUCCESS
local Succeeder = setmetatable({}, {__index = Node})
Succeeder.__index = Succeeder

function Succeeder.new(child)
    local self = setmetatable(Node.new("succeeder"), Succeeder)
    self.child = child
    return self
end

function Succeeder:run(context, dt)
    self.child:run(context, dt)
    return M.STATUS.SUCCESS
end

--- UntilFail: Repeats until child fails
local UntilFail = setmetatable({}, {__index = Node})
UntilFail.__index = UntilFail

function UntilFail.new(child)
    local self = setmetatable(Node.new("until_fail"), UntilFail)
    self.child = child
    return self
end

function UntilFail:run(context, dt)
    local status = self.child:run(context, dt)

    if status == M.STATUS.FAILURE then
        return M.STATUS.SUCCESS
    elseif status == M.STATUS.SUCCESS then
        self.child:reset()
        return M.STATUS.RUNNING
    end

    return M.STATUS.RUNNING
end

--- Cooldown: Prevents child from running for a duration after success
local Cooldown = setmetatable({}, {__index = Node})
Cooldown.__index = Cooldown

function Cooldown.new(child, duration)
    local self = setmetatable(Node.new("cooldown"), Cooldown)
    self.child = child
    self.duration = duration or 1.0
    self.timer = 0
    return self
end

function Cooldown:run(context, dt)
    if self.timer > 0 then
        self.timer = self.timer - dt
        return M.STATUS.FAILURE
    end

    local status = self.child:run(context, dt)

    if status == M.STATUS.SUCCESS then
        self.timer = self.duration
    end

    return status
end

function Cooldown:reset()
    self.timer = 0
    if self.child.reset then self.child:reset() end
end

--- Timeout: Fails if child takes too long
local Timeout = setmetatable({}, {__index = Node})
Timeout.__index = Timeout

function Timeout.new(child, max_time)
    local self = setmetatable(Node.new("timeout"), Timeout)
    self.child = child
    self.max_time = max_time or 5.0
    self.elapsed = 0
    return self
end

function Timeout:run(context, dt)
    self.elapsed = self.elapsed + dt

    if self.elapsed > self.max_time then
        self.elapsed = 0
        return M.STATUS.FAILURE
    end

    local status = self.child:run(context, dt)

    if status ~= M.STATUS.RUNNING then
        self.elapsed = 0
    end

    return status
end

function Timeout:reset()
    self.elapsed = 0
    if self.child.reset then self.child:reset() end
end

-- ============================================================================
-- LEAF NODES
-- ============================================================================

--- Condition: Evaluates a condition function
local Condition = setmetatable({}, {__index = Node})
Condition.__index = Condition

function Condition.new(condition_fn)
    local self = setmetatable(Node.new("condition"), Condition)
    self.condition_fn = condition_fn
    return self
end

function Condition:run(context, dt)
    local result = self.condition_fn(context, dt)
    return result and M.STATUS.SUCCESS or M.STATUS.FAILURE
end

--- Action: Executes an action function
local Action = setmetatable({}, {__index = Node})
Action.__index = Action

function Action.new(action_fn)
    local self = setmetatable(Node.new("action"), Action)
    self.action_fn = action_fn
    return self
end

function Action:run(context, dt)
    local result = self.action_fn(context, dt)
    if result == nil or result == true then
        return M.STATUS.SUCCESS
    elseif result == false then
        return M.STATUS.FAILURE
    else
        return result  -- Allow returning STATUS directly
    end
end

--- Wait: Waits for a duration
local Wait = setmetatable({}, {__index = Node})
Wait.__index = Wait

function Wait.new(duration)
    local self = setmetatable(Node.new("wait"), Wait)
    self.duration = duration or 1.0
    self.elapsed = 0
    return self
end

function Wait:run(context, dt)
    self.elapsed = self.elapsed + dt

    if self.elapsed >= self.duration then
        self.elapsed = 0
        return M.STATUS.SUCCESS
    end

    return M.STATUS.RUNNING
end

function Wait:reset()
    self.elapsed = 0
end

--- WaitRandom: Waits for a random duration
local WaitRandom = setmetatable({}, {__index = Node})
WaitRandom.__index = WaitRandom

function WaitRandom.new(min_duration, max_duration)
    local self = setmetatable(Node.new("wait_random"), WaitRandom)
    self.min_duration = min_duration or 0.5
    self.max_duration = max_duration or 2.0
    self.target_duration = nil
    self.elapsed = 0
    return self
end

function WaitRandom:run(context, dt)
    if not self.target_duration then
        self.target_duration = self.min_duration + math.random() * (self.max_duration - self.min_duration)
    end

    self.elapsed = self.elapsed + dt

    if self.elapsed >= self.target_duration then
        self.elapsed = 0
        self.target_duration = nil
        return M.STATUS.SUCCESS
    end

    return M.STATUS.RUNNING
end

function WaitRandom:reset()
    self.elapsed = 0
    self.target_duration = nil
end

-- ============================================================================
-- BUILDER API
-- ============================================================================

function M.sequence(children)
    return Sequence.new(children)
end

function M.selector(children)
    return Selector.new(children)
end

function M.parallel(children, policy)
    return Parallel.new(children, policy)
end

function M.random_selector(children, weights)
    return RandomSelector.new(children, weights)
end

function M.inverter(child)
    return Inverter.new(child)
end

function M.repeater(child, times)
    return Repeater.new(child, times)
end

function M.succeeder(child)
    return Succeeder.new(child)
end

function M.until_fail(child)
    return UntilFail.new(child)
end

function M.cooldown(child, duration)
    return Cooldown.new(child, duration)
end

function M.timeout(child, max_time)
    return Timeout.new(child, max_time)
end

function M.condition(condition_fn)
    return Condition.new(condition_fn)
end

function M.action(action_fn)
    return Action.new(action_fn)
end

function M.wait(duration)
    return Wait.new(duration)
end

function M.wait_random(min_duration, max_duration)
    return WaitRandom.new(min_duration, max_duration)
end

-- ============================================================================
-- BEHAVIOR TREE WRAPPER
-- ============================================================================

local BehaviorTree = {}
BehaviorTree.__index = BehaviorTree

function BehaviorTree.new(root)
    local self = setmetatable({}, BehaviorTree)
    self.root = root
    self.blackboard = {}  -- Shared data between nodes
    return self
end

function BehaviorTree:run(context, dt)
    context.blackboard = self.blackboard
    return self.root:run(context, dt)
end

function BehaviorTree:reset()
    self.blackboard = {}
    if self.root.reset then self.root:reset() end
end

function BehaviorTree:set(key, value)
    self.blackboard[key] = value
end

function BehaviorTree:get(key)
    return self.blackboard[key]
end

function M.tree(root)
    return BehaviorTree.new(root)
end

return M
