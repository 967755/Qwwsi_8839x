local CONFIG = {
    Name = "OrbLoop",

    RootParent = workspace,
    RootPath = { "GameAssets", "GlobalAssets", "OrbSpawns" },
    RootTimeout = 15,

    ToggleKey = Enum.KeyCode.K,
    AutoStart = false,

    Interval = 0.5,
    TargetCooldown = 0,
    MaxDistance = nil,
    FrameBudgetMs = 1,
    MaxConsecutiveErrors = 10,

    Requires = { "firetouchinterest" },
    Debug = true,
}

local function resolve(obj)
    if obj.Name ~= "Approved" then
        return nil
    end

    local part = obj.Parent
    if not part then
        return nil
    end

    if not part:IsA("BasePart") then
        return nil, "parent is a " .. part.ClassName .. ", expected a BasePart"
    end

    return part
end

local function act(root, target)
    if not target.CanTouch then
        return
    end

    firetouchinterest(root, target, 0)
    firetouchinterest(root, target, 1)
end

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local pcall, typeof, ipairs = pcall, typeof, ipairs
local clock, clear = os.clock, table.clear
local spawn, wait = task.spawn, task.wait

local genv = getgenv and getgenv() or _G
local NAME = tostring(CONFIG.Name)
local TAG = "[" .. NAME .. "]"

local function findProblems()
    local problems = {}

    for _, fnName in ipairs(CONFIG.Requires or {}) do
        if type(genv[fnName]) ~= "function" then
            problems[#problems + 1] = "executor function missing: " .. tostring(fnName)
        end
    end

    if typeof(CONFIG.RootParent) ~= "Instance" then
        problems[#problems + 1] = "RootParent must be an Instance"
    end

    if type(CONFIG.RootPath) ~= "table" then
        problems[#problems + 1] = "RootPath must be a table of names"
    else
        for _, childName in ipairs(CONFIG.RootPath) do
            if type(childName) ~= "string" then
                problems[#problems + 1] = "RootPath entries must be strings"
                break
            end
        end
    end

    return problems
end

local problems = findProblems()
if #problems > 0 then
    warn(TAG, table.concat(problems, "; "))
    return
end

genv.__Loops = genv.__Loops or {}
local previous = genv.__Loops[NAME]
if previous then
    pcall(previous.Destroy)
end

local player = Players.LocalPlayer
while not player do
    wait()
    player = Players.LocalPlayer
end

local function clampNumber(value, fallback, min, max)
    return math.clamp(tonumber(value) or fallback, min, max)
end

local DEBUG = CONFIG.Debug == true
local INTERVAL = clampNumber(CONFIG.Interval, 0.5, 0.03, 3600)
local COOLDOWN = clampNumber(CONFIG.TargetCooldown, 0, 0, 3600)
local FRAME_BUDGET = clampNumber(CONFIG.FrameBudgetMs, 1, 0.1, 8) / 1000
local MAX_ERRORS = math.floor(clampNumber(CONFIG.MaxConsecutiveErrors, 10, 1, 1000))
local ROOT_TIMEOUT = clampNumber(CONFIG.RootTimeout, 15, 1, 600)
local SCAN_BATCH = 500

local MAX_DISTANCE = tonumber(CONFIG.MaxDistance)
local MAX_DISTANCE_SQ = MAX_DISTANCE and MAX_DISTANCE * MAX_DISTANCE or nil

local Log = {}
local seen = setmetatable({}, { __mode = "k" })
local lastChange = nil

function Log.trace(...)
    if DEBUG then
        print(TAG, ...)
    end
end

function Log.change(message)
    if DEBUG and message ~= lastChange then
        lastChange = message
        if message then
            print(TAG, message)
        end
    end
end

function Log.once(key, ...)
    if not seen[key] then
        seen[key] = true
        warn(TAG, ...)
    end
end

function Log.rejected(obj, reason)
    if DEBUG and not seen[obj] then
        seen[obj] = true
        print(TAG, "skipped", obj:GetFullName(), "-", tostring(reason))
    end
end

local function newMaid()
    local items = {}
    local maid = {}

    function maid.give(connection)
        items[#items + 1] = connection
        return connection
    end

    function maid.clean()
        for i = #items, 1, -1 do
            local connection = items[i]
            items[i] = nil
            connection:Disconnect()
        end
    end

    return maid
end

local alive = true
local enabled = false
local stats = { sweeps = 0, actions = 0, errors = 0 }

local api = {}
local Targets = {}
local Container = {}
local Scheduler = {}
local Control = {}

local rootMaid = newMaid()
local inputMaid = newMaid()

local targetList = {}
local targetIndex = {}
local targetCount = 0
local lastActed = {}

function Targets.add(target)
    if targetIndex[target] then
        return
    end

    targetCount = targetCount + 1
    targetList[targetCount] = target
    targetIndex[target] = targetCount
end

function Targets.remove(target)
    local index = targetIndex[target]
    if not index then
        return
    end

    local last = targetList[targetCount]
    targetList[index] = last
    targetIndex[last] = index
    targetList[targetCount] = nil
    targetIndex[target] = nil
    lastActed[target] = nil
    targetCount = targetCount - 1
end

function Targets.clear()
    clear(targetList)
    clear(targetIndex)
    clear(lastActed)
    targetCount = 0
end

local function getCharacterRoot()
    local character = player.Character
    if not character then
        return nil, "character does not exist"
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health <= 0 then
        return nil, "character is dead"
    end

    local root = character:FindFirstChild("HumanoidRootPart")
    if not root or not root:IsA("BasePart") then
        return nil, "HumanoidRootPart is not a child of the character"
    end

    if not root:IsDescendantOf(Workspace) then
        return nil, "character is not in Workspace"
    end

    return root
end

local function positionOf(target)
    if target:IsA("BasePart") then
        return target.Position
    elseif target:IsA("Model") then
        return target:GetPivot().Position
    elseif target:IsA("Attachment") then
        return target.WorldPosition
    end

    local part = target:FindFirstAncestorWhichIsA("BasePart")
    if part then
        return part.Position
    end

    local model = target:FindFirstAncestorWhichIsA("Model")
    if model then
        return model:GetPivot().Position
    end

    return nil
end

local function isWithinRange(target, origin)
    local ok, position = pcall(positionOf, target)
    if not ok or not position then
        return false
    end

    local offset = position - origin
    return offset:Dot(offset) <= MAX_DISTANCE_SQ
end

local boundContainer = nil
local generation = 0
local acquiring = false

function Container.track(obj)
    local ok, result, reason = pcall(resolve, obj)
    if not ok then
        Log.once(tostring(result), "resolve failed:", result)
        return
    end

    if typeof(result) ~= "Instance" then
        if reason then
            Log.rejected(obj, reason)
        end
        return
    end

    if DEBUG and boundContainer and not result:IsDescendantOf(boundContainer) then
        Log.rejected(obj, result:GetFullName() .. " is not a descendant of " .. boundContainer:GetFullName())
    end

    Targets.add(result)
end

function Container.untrack(obj)
    local ok, result = pcall(resolve, obj)
    if ok and typeof(result) == "Instance" then
        Targets.remove(result)
    end
end

function Container.scan(container, scanGeneration)
    local descendants = container:GetDescendants()
    local total = #descendants

    for i = 1, total do
        if not alive or scanGeneration ~= generation then
            return
        end

        Container.track(descendants[i])

        if i % SCAN_BATCH == 0 then
            wait()
        end
    end

    Log.trace("scan finished:", total, "descendants,", targetCount, "targets")
end

function Container.unbind()
    generation = generation + 1
    boundContainer = nil
    rootMaid.clean()
    Targets.clear()
end

function Container.bind(container)
    Container.unbind()
    boundContainer = container

    rootMaid.give(container.DescendantAdded:Connect(Container.track))
    rootMaid.give(container.DescendantRemoving:Connect(Container.untrack))
    rootMaid.give(container.AncestryChanged:Connect(function()
        if alive and not container:IsDescendantOf(game) then
            Log.trace("container was removed, searching again")
            Container.unbind()
            spawn(Container.acquire)
        end
    end))

    spawn(Container.scan, container, generation)
end

local function findPath(parent, path, timeout)
    local deadline = clock() + timeout
    local node = parent

    for _, childName in ipairs(path) do
        local child = node:FindFirstChild(childName)

        if not child then
            local remaining = deadline - clock()
            if remaining > 0 then
                child = node:WaitForChild(childName, remaining)
            end
        end

        if not child then
            return nil, node, childName
        end

        node = child
    end

    return node
end

function Container.acquire()
    if acquiring then
        return
    end
    acquiring = true

    while alive do
        local container, parent, missing = findPath(CONFIG.RootParent, CONFIG.RootPath, ROOT_TIMEOUT)
        if not alive then
            break
        end

        if container then
            Log.trace("watching", container:GetFullName())
            Container.bind(container)
            break
        end

        local message = "'" .. missing .. "' is not a child of " .. parent:GetFullName()
        Log.once(message, message)
    end

    acquiring = false
end

local heartbeat = nil
local busy = false
local idleTime = 0
local sweeping = false
local cursor = 0
local sweepRoot = nil
local errorStreak = 0

local function resetSweep()
    sweeping = false
    cursor = 0
    sweepRoot = nil
end

local function beginSweep()
    local root, reason = getCharacterRoot()
    if not root then
        Log.change(reason)
        return false
    end

    if targetCount == 0 then
        Log.change("no targets registered")
        return false
    end

    Log.change(nil)
    sweepRoot = root
    cursor = targetCount
    sweeping = true
    return true
end

local function nextTarget()
    if cursor > targetCount then
        cursor = targetCount
    end

    if cursor < 1 then
        return nil
    end

    local target = targetList[cursor]
    cursor = cursor - 1
    return target
end

local function handleTarget(target, origin, now)
    if target.Parent == nil then
        Log.trace("target no longer exists:", target.Name)
        Targets.remove(target)
        return
    end

    if MAX_DISTANCE_SQ and not isWithinRange(target, origin) then
        return
    end

    if COOLDOWN > 0 then
        local last = lastActed[target]
        if last and now - last < COOLDOWN then
            return
        end
        lastActed[target] = now
    end

    local ok, err = pcall(act, sweepRoot, target)
    if ok then
        errorStreak = 0
        stats.actions = stats.actions + 1
        return
    end

    stats.errors = stats.errors + 1
    errorStreak = errorStreak + 1

    if errorStreak <= 3 then
        warn(TAG, "act failed on", target:GetFullName(), "-", err)
    end

    if errorStreak >= MAX_ERRORS then
        warn(TAG, "too many consecutive errors, turned off")
        Control.setEnabled(false)
    end
end

local function step(dt)
    if not sweeping then
        idleTime = idleTime + dt
        if idleTime < INTERVAL then
            return
        end

        idleTime = 0
        if not beginSweep() then
            return
        end
    end

    if not sweepRoot.Parent then
        Log.trace("character root was removed mid-sweep")
        resetSweep()
        return
    end

    local now = clock()
    local deadline = now + FRAME_BUDGET
    local origin = sweepRoot.Position

    local target = nextTarget()
    while target do
        handleTarget(target, origin, now)

        if not enabled or clock() >= deadline then
            break
        end

        target = nextTarget()
    end

    if not enabled then
        return
    end

    if cursor < 1 then
        stats.sweeps = stats.sweeps + 1
        resetSweep()
    end
end

local function onHeartbeat(dt)
    if busy then
        return
    end

    busy = true
    local ok, err = pcall(step, dt)
    busy = false

    if not ok then
        warn(TAG, "scheduler error, turned off:", err)
        Control.setEnabled(false)
    end
end

function Scheduler.start()
    if heartbeat then
        return
    end

    errorStreak = 0
    idleTime = INTERVAL
    heartbeat = RunService.Heartbeat:Connect(onHeartbeat)
end

function Scheduler.stop()
    if heartbeat then
        heartbeat:Disconnect()
        heartbeat = nil
    end

    resetSweep()
end

function Control.setEnabled(state)
    state = state and true or false
    if not alive or state == enabled then
        return
    end

    enabled = state

    if enabled then
        Scheduler.start()
    else
        Scheduler.stop()
    end

    Log.trace(enabled and "enabled" or "disabled")
end

function Control.toggle()
    Control.setEnabled(not enabled)
end

function Control.destroy()
    if not alive then
        return
    end

    alive = false
    enabled = false
    Scheduler.stop()
    inputMaid.clean()
    Container.unbind()

    if genv.__Loops[NAME] == api then
        genv.__Loops[NAME] = nil
    end

    Log.trace("destroyed")
end

api.SetEnabled = Control.setEnabled
api.Toggle = Control.toggle
api.Destroy = Control.destroy

function api.IsEnabled()
    return enabled
end

function api.GetTargetCount()
    return targetCount
end

function api.GetStats()
    return {
        sweeps = stats.sweeps,
        actions = stats.actions,
        errors = stats.errors,
        targets = targetCount,
    }
end

if CONFIG.ToggleKey then
    inputMaid.give(UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if not gameProcessed and input.KeyCode == CONFIG.ToggleKey then
            Control.toggle()
        end
    end))
end

genv.__Loops[NAME] = api
spawn(Container.acquire)

if CONFIG.AutoStart then
    Control.setEnabled(true)
end

Log.trace("loaded, toggle key:", CONFIG.ToggleKey and CONFIG.ToggleKey.Name or "none")
