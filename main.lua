loadstring([==[
-- Kaitun.lua: Blox Fruits kaitun framework (Luau, executor environment)
-- Every game-specific value lives in Config. UNSET is distinct from nil/0/false.
-- Provenance tags: [ASSUMED] = from general knowledge, unverified on your build.
--                  [UNSET]   = missing, feature gated until you fill it.
-- Target: Delta Executor (mobile). Paste the whole file into Delta's script box and execute.
-- Executor APIs used, all [ASSUMED] present on Delta and checked at runtime:
--   getgenv (re-run guard), gethui (UI parent), firetouchinterest (fruit pickup).
-- Re-executing this file shuts the previous instance down first.
-- Researched against Update 30.1 (Halloween build, live as of 2026-11-13 per timesaver.gg).
-- Sites disagree on update numbering (some call mid-2026 balance patches 31.x), so this is keyed by date.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UNSET = setmetatable({}, { __tostring = function() return "UNSET" end })
local function isSet(v) return v ~= UNSET and v ~= nil end

local Config = {
	-- [ASSUMED] verify with: print(game.PlaceId) in each sea
	places = { sea1 = 2753915549, sea2 = 4442272183, sea3 = 7449423635 },

	-- [RESEARCH] Update 30.0 (2026-09-05): normal grinding stops at 2800. Island Secrets in Sea 1
	-- (200 secret levels) raise the cap to 3000. Sources: Fandom Update 30.0, beebom, allthings.how.
	-- This script does not do Island Secrets; farmLevel stops at `grind`.
	levelCap = { grind = 2800, withSecrets = 3000 },

	-- [ASSUMED] ReplicatedStorage.Remotes.<name>; verify in Explorer
	commRemoteName = "CommF_",

	-- [ASSUMED] path to the player's level value; verify under LocalPlayer in Explorer.
	-- Update 30 reworked the HUD and stats menu, so recheck this path on the current build.
	levelPath = { "Data", "Level" },

	-- [UNSET] sorted ascending by minLevel. Entry shape:
	-- { minLevel=, maxLevel=, sea=, npcName=, questName=, questIndex=, mobName=, mobArea=CFrame }
	-- Update 30 reworked Sea 1 island by island, so any old quest table or mob area is stale.
	-- Recipe: take one quest by hand with a remote spy open, read the CommF_ args,
	-- read the NPC name in workspace.NPCs, read mob names in workspace.Enemies.
	questTable = UNSET,

	-- [UNSET] Recipe: spy the remote your M1 click fires; record remote path + arg shape.
	fastAttack = { remotePath = UNSET, buildArgs = UNSET },

	-- [UNSET] Recipe: talk to the God Human NPC in the sea that has him,
	-- copy the requirement dialog, then fill the CommF_ args you see in the spy.
	godHuman = { requirements = UNSET, buyArgs = UNSET },

	-- [UNSET] Recipe: spy the raid start button, the chip purchase and the island
	-- progression remotes in one full manual raid.
	raid = { chipArgs = UNSET, startArgs = UNSET },

	-- [UNSET] Recipe: spy the Mirage Island steps by hand once and record args.
	blueGear = { steps = UNSET },

	-- [RESEARCH] PvP loadout names, from public guides found on 2026-11-24 (esports.gg fighting
	-- style list for Update 31, rblxguide accessory list June 2026, bloxmeta PvP guide, techwiser).
	-- Guides disagree with each other and go stale each update, so this is a priority list of
	-- NAMES only; edit freely. Order = acquire order. Names are not verified against your build.
	pvpLoadout = {
		fightingStyles = { "Sharkman Karate", "Electric Claw", "Dragon Talon", "Godhuman", "Sanguine Art" },
		swords = { "Cursed Dual Katana", "Yoru", "True Triple Katana", "Saber V2" },
		accessories = { "Pale Scarf", "Swan Glasses", "Kitsune Ribbon" },
		fruits = { "Buddha", "Dragon", "Dough", "Tiger" }, -- Tiger is the reworked Leopard (Update 28, GameSpot)
	},

	-- [DERIVED] bloxmeta's PvP guide split the old 2550 cap as Melee 400, Defense 400, main stat 1750.
	-- For the 2800 grind cap the same split gives main stat 2000 (2800 - 400 - 400). That is my
	-- arithmetic, not a published build, and Update 30 reworked the stats menu, so confirm it.
	-- Sword hybrid: put the main stat on Sword instead. Edit targets to taste.
	stats = {
		order = { "Melee", "Defense", "Fruit" },
		targets = { Melee = 400, Defense = 400, Fruit = 2000 },
		-- [UNSET] functions you provide after reading your stat UI / remotes:
		readCurrent = UNSET, -- () -> { Melee=n, Defense=n, Fruit=n, ... } or nil on failure
		readPoints = UNSET, -- () -> number of unspent points, or nil on failure
		allocate = UNSET, -- (commRemote, statName, amount) -> fires the allocate remote
	},

	-- [UNSET] Recipe: buy or earn each item by hand once with the remote spy open.
	acquire = {
		isOwned = UNSET, -- (kind, name) -> true | false | nil when unknown
		obtain = UNSET, -- (commRemote, kind, name) -> true when the step was fired
	},

	-- [UNSET] Armament (Buso) and Observation (Ken) toggles. Recipe: spy the toggle remotes.
	-- Per the rblxguide/nerdstash notes, some fruit passives need Aura active to deal damage.
	haki = { enableBuso = UNSET, enableKen = UNSET },

	-- [UNSET] level gates and travel calls between seas. Recipe: read the travel NPC dialog.
	seaTravel = { minLevelSea2 = UNSET, minLevelSea3 = UNSET, travel = UNSET },
}

-- Pure functions, checkable without the game.

local function pickQuest(level, quests)
	if type(level) ~= "number" or level ~= level then return nil end
	for i = #quests, 1, -1 do
		local q = quests[i]
		if level >= q.minLevel and level <= q.maxLevel then return q end
	end
	return nil
end

local function isFruitName(name)
	return type(name) == "string" and name:sub(-5) == "Fruit"
end

-- Stat plan: spend unspent points on stats in `order` until each reaches its target.
-- Returns a list of { stat=, amount= }. Bad numbers produce an empty plan, never a guess.
local function planStats(current, targets, order, points)
	local out = {}
	if type(current) ~= "table" or type(points) ~= "number" or points ~= points or points <= 0 then
		return out
	end
	for _, stat in ipairs(order) do
		local have, want = current[stat], targets[stat]
		if type(have) == "number" and type(want) == "number" and have < want then
			local give = math.min(want - have, points)
			out[#out + 1] = { stat = stat, amount = give }
			points -= give
			if points <= 0 then break end
		end
	end
	return out
end

-- First loadout item that isOwned reports as false. nil owned status is skipped, not assumed.
local KIND_ORDER = { "fightingStyles", "swords", "accessories", "fruits" }

local function nextMissing(loadout, isOwned)
	for _, kind in ipairs(KIND_ORDER) do
		for _, name in ipairs(loadout[kind] or {}) do
			if isOwned(kind, name) == false then return kind, name end
		end
	end
	return nil
end

-- World access, all validated.

local function getCharacter()
	local char = Players.LocalPlayer.Character
	if not char then return nil end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hrp or not hum or hum.Health <= 0 then return nil end
	return char, hrp, hum
end

local function readLevel()
	local node = Players.LocalPlayer
	for _, key in ipairs(Config.levelPath) do
		node = node and node:FindFirstChild(key)
	end
	if node and typeof(node.Value) == "number" then return node.Value end
	return nil -- failure, never a fake 0
end

local function getComm()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	return remotes and remotes:FindFirstChild(Config.commRemoteName)
end

-- Features. Each returns a tick function; Runner gates on `requires`.

local Features = {}

-- [ASSUMED] dropped fruits are Tools named "<X> Fruit" directly under workspace.
Features.collectFruits = {
	requires = {},
	tick = function()
		local _, hrp = getCharacter()
		if not hrp then return end
		for _, inst in ipairs(workspace:GetChildren()) do
			if inst:IsA("Tool") and isFruitName(inst.Name) then
				local handle = inst:FindFirstChild("Handle")
				if handle then
					hrp.CFrame = handle.CFrame
					if firetouchinterest then
						firetouchinterest(hrp, handle, 0)
						firetouchinterest(hrp, handle, 1)
					end
				end
			end
		end
	end,
}

Features.farmLevel = {
	requires = { "questTable" },
	tick = function()
		local level = readLevel()
		if level and level >= Config.levelCap.grind then return end -- no EXP past the grind cap
		local quest = level and pickQuest(level, Config.questTable)
		if not quest then return end
		-- Quest accept / mob teleport / attack loop goes here once questTable
		-- args are filled; kept out because the CommF_ arg shape is [UNSET].
	end,
}

Features.fastAttack = {
	requires = { "fastAttack.remotePath", "fastAttack.buildArgs" },
	tick = function() end, -- fires Config.fastAttack remote once both are set
}

Features.godHuman = {
	requires = { "godHuman.requirements", "godHuman.buyArgs" },
	tick = function() end,
}

Features.raid = {
	requires = { "raid.chipArgs", "raid.startArgs" },
	tick = function() end,
}

Features.blueGear = {
	requires = { "blueGear.steps" },
	tick = function() end,
}

Features.autoStats = {
	requires = { "stats.readCurrent", "stats.readPoints", "stats.allocate" },
	tick = function()
		local comm = getComm()
		if not comm then return end
		local current, points = Config.stats.readCurrent(), Config.stats.readPoints()
		for _, step in ipairs(planStats(current, Config.stats.targets, Config.stats.order, points)) do
			Config.stats.allocate(comm, step.stat, step.amount)
		end
	end,
}

-- One missing PvP item per tick, in loadout order.
Features.acquirePvpLoadout = {
	requires = { "acquire.isOwned", "acquire.obtain" },
	tick = function()
		local comm = getComm()
		if not comm then return end
		local kind, name = nextMissing(Config.pvpLoadout, Config.acquire.isOwned)
		if kind then Config.acquire.obtain(comm, kind, name) end
	end,
}

local lastHakiAt = 0
Features.autoHaki = {
	requires = { "haki.enableBuso", "haki.enableKen" },
	tick = function()
		if os.clock() - lastHakiAt < 5 then return end -- idempotency of the toggle is unknown
		lastHakiAt = os.clock()
		local comm = getComm()
		if not comm then return end
		Config.haki.enableBuso(comm)
		Config.haki.enableKen(comm)
	end,
}

Features.seaTravel = {
	requires = { "seaTravel.minLevelSea2", "seaTravel.minLevelSea3", "seaTravel.travel" },
	tick = function()
		local comm = getComm()
		local level = readLevel()
		if not comm or not level then return end
		local cfg = Config.seaTravel
		local target = (level >= cfg.minLevelSea3 and 3) or (level >= cfg.minLevelSea2 and 2) or nil
		local currentSea = (game.PlaceId == Config.places.sea3 and 3)
			or (game.PlaceId == Config.places.sea2 and 2)
			or (game.PlaceId == Config.places.sea1 and 1) or nil
		if target and currentSea and currentSea < target then cfg.travel(comm, target) end
	end,
}

-- Runner with one cleanup path.

local function resolve(path)
	local node = Config
	for part in path:gmatch("[^.]+") do
		node = node and node[part]
	end
	return node
end

local env = (getgenv and getgenv()) or _G
if env.KaitunInstance then pcall(env.KaitunInstance.shutdown) end

local running, paused, connection, gui = true, false, nil, nil

local function shutdown()
	running = false
	if connection then connection:Disconnect() connection = nil end
	if gui then gui:Destroy() gui = nil end
	env.KaitunInstance = nil
end

local active, gated = {}, {}
for name, feature in pairs(Features) do
	local missing = {}
	for _, path in ipairs(feature.requires) do
		if not isSet(resolve(path)) then missing[#missing + 1] = path end
	end
	if #missing == 0 then
		active[name] = feature
	else
		gated[name] = missing
	end
end

for name, missing in pairs(gated) do
	warn(("[Kaitun] %s gated, missing: %s"):format(name, table.concat(missing, ", ")))
end

if not getComm() then
	warn("[Kaitun] CommF_ remote not found, check Config.commRemoteName")
end

local accumulator = 0
connection = RunService.Heartbeat:Connect(function(dt)
	if not running or paused then return end
	accumulator += dt
	if accumulator < 0.25 then return end
	accumulator = 0
	for name, feature in pairs(active) do
		local ok, err = pcall(feature.tick)
		if not ok then warn(("[Kaitun] %s error: %s"):format(name, tostring(err))) end
	end
end)

-- Touch-friendly UI: status line, Pause/Resume, Stop. 44px buttons for fingers.
-- Parent order: gethui, CoreGui, PlayerGui. If none accepts it, run headless.
local function mountGui()
	local g = Instance.new("ScreenGui")
	g.Name = "KaitunUI"
	g.ResetOnSpawn = false

	local getters = {
		function() return gethui and gethui() end,
		function() return game:GetService("CoreGui") end,
		function() return Players.LocalPlayer:WaitForChild("PlayerGui", 5) end,
	}
	local placed = false
	for _, getParent in ipairs(getters) do
		local ok, parent = pcall(getParent)
		if ok and parent then
			pcall(function() g.Parent = parent end)
			if g.Parent == parent then placed = true break end
		end
	end
	if not placed then g:Destroy() return nil end

	local activeCount, gatedCount = 0, 0
	for _ in pairs(active) do activeCount += 1 end
	for _ in pairs(gated) do gatedCount += 1 end

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(204, 44)
	label.Position = UDim2.fromOffset(8, 8)
	label.TextWrapped = true
	label.Text = ("Kaitun: %d active, %d gated"):format(activeCount, gatedCount)
	label.Parent = g

	local pauseButton = Instance.new("TextButton")
	pauseButton.Size = UDim2.fromOffset(100, 44)
	pauseButton.Position = UDim2.fromOffset(8, 56)
	pauseButton.Text = "Pause"
	pauseButton.Parent = g
	pauseButton.Activated:Connect(function()
		paused = not paused
		pauseButton.Text = paused and "Resume" or "Pause"
	end)

	local stopButton = Instance.new("TextButton")
	stopButton.Size = UDim2.fromOffset(100, 44)
	stopButton.Position = UDim2.fromOffset(112, 56)
	stopButton.Text = "Stop"
	stopButton.Parent = g
	stopButton.Activated:Connect(shutdown)

	return g
end

gui = mountGui()

local api = {
	Config = Config,
	shutdown = shutdown,
	pickQuest = pickQuest,
	planStats = planStats,
	nextMissing = nextMissing,
}
env.KaitunInstance = api
return api

]==])()
