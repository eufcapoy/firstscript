-- Force Obsidian into PlayerGui to avoid 'lacking capability Plugin' on CoreGui
local _origGethui = gethui
local _playerGui = game.Players.LocalPlayer:WaitForChild("PlayerGui", 10)
gethui = function() return _playerGui end
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/refs/heads/main/Library.lua"))()
gethui = _origGethui
if not Library then error("[ryujin] Obsidian failed to load") end

-- Standalone fallback for plain execute/execute-file (no live-reload STATE):
-- keeps STATE.alive() true and collects onCleanup callbacks instead of
-- indexing nil, which previously killed every refresh loop on line 1.
if not STATE then
	local cleanups = {}
	STATE = {
		_alive = true,
		alive = function(self)
			return self._alive
		end,
		onCleanup = function(self, fn)
			table.insert(cleanups, fn)
		end,
	}
end

local lp = game.Players.LocalPlayer
local run = game:GetService("RunService")
local RS = game.ReplicatedStorage
local JA = workspace.Ignore.Interactables.JobsRelated

if getgenv().__flyStop then
	pcall(getgenv().__flyStop)
end

local FLY = { enabled = false, speed = 120, target = nil, bv = nil, saved = {}, hold = false, cancel = false, busy = false, token = 0 }

-- Gang-base kick detection state. KICK.detected is set by the kick watcher
-- when the server teleports the character out of the gang base while working.
local KICK = { detected = false, pos = nil, time = 0 }
-- No-go zone around the gang base district (Workspace.Map.Gangbase bounding
-- box on XZ, plus a margin) and any kick locations learned at runtime.
local GANG_BASE = { x1 = 51, z1 = -54, x2 = 1608, z2 = 666, margin = 60 }
local GANG_ZONES = {}

-- Sent down to the flight loop below but only initialized later in the file.
-- Forward-declared here so the loop closure captures them as upvalues.
local rwConfig
local rwState
-- Fatigue recovery: defined later in the file, called by the training loops.
local recover
local recoverFatigue

local function flyStop()
	FLY.enabled = false
	if FLY.bv then
		FLY.bv:Destroy()
		FLY.bv = nil
	end
	for part, collidable in pairs(FLY.saved) do
		if part.Parent then part.CanCollide = collidable end
	end
	FLY.saved = {}
	-- Restore humanoid state so character doesn't float
	local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		if FLY._savedHipHeight then hum.HipHeight = FLY._savedHipHeight end
		if FLY._savedWalkSpeed then hum.WalkSpeed = FLY._savedWalkSpeed end
		if FLY._savedPlatform ~= nil then hum.PlatformStand = FLY._savedPlatform end
		hum:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
	FLY._savedHipHeight = nil
	FLY._savedWalkSpeed = nil
	FLY._savedPlatform = nil
end

local function flyTo(pos, ignoreCancel)
	local root = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	if not root then return "no character" end
	if FLY.cancel and not ignoreCancel then return "cancelled" end
	if KICK.detected and not ignoreCancel then return "kicked" end
	local hum = lp.Character:FindFirstChild("Humanoid")
	if hum then
		if not FLY._savedWalkSpeed then FLY._savedWalkSpeed = hum.WalkSpeed end
		if FLY._savedPlatform == nil then FLY._savedPlatform = hum.PlatformStand end
		hum.WalkSpeed = FLY.speed
		hum.PlatformStand = true
		if not FLY._savedHipHeight then FLY._savedHipHeight = hum.HipHeight end
		hum.HipHeight = 0
	end
	root.Anchored = false
	FLY.saved = {}
	if lp.Character then
		for _, part in ipairs(lp.Character:GetDescendants()) do
			if part:IsA("BasePart") then FLY.saved[part] = part.CanCollide end
		end
	end
	if not FLY.bv then
		local bv = Instance.new("BodyVelocity")
		bv.MaxForce = Vector3.new(1e9, 1e9, 1e9)
		bv.Parent = root
		FLY.bv = bv
	end
	FLY.enabled = true
	FLY.hold = false
	FLY.target = Vector3.new(pos.X, pos.Y, pos.Z)
	return true
end

local function flyHold()
	FLY.enabled = true
	FLY.hold = true
	FLY.target = nil
	local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
	if hum and FLY._savedWalkSpeed then
		hum.WalkSpeed = FLY._savedWalkSpeed
	end
end

local function waitFlightIdle()
	while FLY.busy do task.wait(0.2) end
end

local function takeFlightControl()
	local t = FLY.token + 1
	FLY.token = t
	FLY.cancel = true
	FLY.busy = true
	return t
end

local function releaseFlightControl(myToken)
	if myToken == FLY.token then
		FLY.cancel = false
		FLY.busy = false
	end
end

getgenv().__flyTo = flyTo
getgenv().__flyStop = flyStop
getgenv().__flyHold = flyHold

run.Heartbeat:Connect(function()
	local root = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		FLY.enabled = false
		return
	end
	if FLY.bv and not FLY.bv.Parent then
		FLY.bv = nil
	end
	if not FLY.bv or not FLY.enabled then return end
	-- Noclip all character parts
	for _, part in ipairs(lp.Character:GetDescendants()) do
		if part:IsA("BasePart") and part.CanCollide then part.CanCollide = false end
	end
	-- Roadwork flip: while enabled the character hangs upside down the whole
	-- run (feet up, head below the HRP), so the name tag stays buried under
	-- the road even on checkpoints that force the pop. Roadwork-only.
	if rwConfig.flip and rwState.running then
		root.CFrame = CFrame.new(root.Position) * CFrame.Angles(math.pi, 0, 0)
	end
	if FLY.hold then
		FLY.bv.Velocity = Vector3.zero
		return
	end
	if not FLY.target then return end
	local dir = FLY.target - root.Position
	local dist = dir.Magnitude
	if dist < 2.5 then
		FLY.bv.Velocity = Vector3.zero
		return
	end
	local v = dir.Unit * math.min(FLY.speed, dist * 1.5)
	v = Vector3.new(v.X, math.clamp(v.Y, -50, 50), v.Z)
	FLY.bv.Velocity = v
end)

local jobs = require(RS.Modules.Client.GUIs.Main.jobs)
local Utility = require(RS.Modules.Shared.Utility)
local Warp = require(RS.Packages.Warp)
local JobsCh = Warp.Client("Jobs")
local BankCh = Warp.Client("Bank")
local CollectionService = game:GetService("CollectionService")
local SignalHandler = require(RS.Modules.Shared.SignalHandler)
local WarpSig = SignalHandler.Get("Warp")
local TrainingsCh = Warp.Client("Trainings")
local CircleMod = require(RS.Modules.Client.GUIs.Secondary.trainings.Circle)
local SquareMod = require(RS.Modules.Client.GUIs.Secondary.trainings.Square)

local outcome = { last = nil }
local origCleanup = jobs.Cleanup
jobs.Cleanup = function(p1, p2)
	outcome.last = (p2 == true) and "success" or "fail"
	return origCleanup(p1, p2)
end

local function getCash()
	local ok, data = pcall(Utility.SnipeData, lp)
	if ok and typeof(data) == "Instance" then
		local c = data:FindFirstChild("Cash")
		if c and c:IsA("NumberValue") then return c.Value end
	end
	return nil
end

local function rootPos()
	local root = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	return root and root.Position or nil
end

local function insideGangZone(x, z)
	if x >= GANG_BASE.x1 - GANG_BASE.margin and x <= GANG_BASE.x2 + GANG_BASE.margin
		and z >= GANG_BASE.z1 - GANG_BASE.margin and z <= GANG_BASE.z2 + GANG_BASE.margin then
		return true
	end
	for _, zz in ipairs(GANG_ZONES) do
		if (x - zz.x) * (x - zz.x) + (z - zz.z) * (z - zz.z) <= zz.r * zz.r then
			return true
		end
	end
	return false
end

local function waitArrive(timeout, ignoreCancel)
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		if KICK.detected and not ignoreCancel then return "kicked" end
		if not FLY.enabled then return true end
		if FLY.hold then return true end
		if not ignoreCancel and FLY.cancel then return "cancelled" end
		local p = rootPos()
		if p and FLY.target and (p - FLY.target).Magnitude < 3.5 then return true end
		task.wait(0.1)
	end
	return not FLY.enabled
end

local function progressOf(aj)
	if not aj then return 0, 0 end
	local done, total = 0, 0
	for _, o in ipairs(aj.objectives or {}) do
		done += o.progress or 0
		total += o.qt or 0
	end
	return done, total
end

-- ============ AUTO BANK ============
-- bankAt: when cash crosses above this threshold, the WHOLE cash balance is
-- deposited (not just the excess). The bot then works from ~0 back up to
-- bankAt before banking again, so ATM trips are rare instead of every job.
local autoBank = { enabled = false, bankAt = 100000, noAccountNotified = false }
getgenv().__bankState = autoBank

local function bankAccount()
	local ok, data = pcall(Utility.SnipeData, lp)
	if not ok or typeof(data) ~= "Instance" then return nil end
	return data:FindFirstChild("Bank")
end

local function nearestATM()
	local me = rootPos()
	if not me then return nil end
	local best, bestD = nil, math.huge
	for _, m in ipairs(CollectionService:GetTagged("ATM")) do
		local pp = m.PrimaryPart
		if pp and not m:GetAttribute("Broken") then
			local pos = pp.Position
			if not insideGangZone(pos.X, pos.Z) then
				local d = (pos - me).Magnitude
				if d < bestD then
					bestD = d
					best = { model = m, part = pp, cd = pp:FindFirstChildOfClass("ClickDetector") }
				end
			end
		end
	end
	return best
end

-- Forward declarations: depositExcess below uses these, but they are defined
-- later in the file. Without the declaration the calls resolve to nil globals.
local undergroundOf
local flyUndergroundTo
local bot

local function depositExcess()
	if not autoBank.enabled then return "disabled" end
	local bk = bankAccount()
	if not bk then return "no bank data" end
	local unlocked = bk:FindFirstChild("Unlocked")
	if not (unlocked and unlocked.Value) then
		if not autoBank.noAccountNotified then
			autoBank.noAccountNotified = true
			Library:Notify({ Title = "Auto Bank", Description = "No bank account - open one at any ATM to use Auto Bank", Time = 5 })
		end
		return "no account"
	end
	autoBank.noAccountNotified = false
	local cash = getCash()
	if not cash or cash < autoBank.bankAt then return "nothing to store" end
	local atm = nearestATM()
	if not atm then return "no atm" end
	local amount = math.floor(cash)
	local myToken = takeFlightControl()
	-- Stay at the same underground depth the job bot uses: dive below the ATM
	-- instead of surfacing. fireclickdetector ignores distance, and the ATM
	-- GUI stays open within 20 studs of its Screen, which is ~9 from under it.
	local result = nil
	local ok, err = pcall(function()
		local dest = undergroundOf(atm.part.Position, 12) or atm.part.Position
		local rf = flyUndergroundTo(dest, true, myToken)
		if rf == "cancelled" or rf == "kicked" or rf == "superseded" then
			result = rf
			return
		end
		flyHold()
		task.wait(0.3)
		if atm.cd then
			fireclickdetector(atm.cd, 0, "MouseClick")
		end
		task.wait(0.8)
		local atmGui = lp.PlayerGui and lp.PlayerGui:FindFirstChild("HUD") and lp.PlayerGui.HUD:FindFirstChild("Tabs") and lp.PlayerGui.HUD.Tabs:FindFirstChild("ATM")
		if atmGui and atmGui:FindFirstChild("AmountBox") then
			atmGui.AmountBox.Text = tostring(amount)
		end
		task.wait(0.2)
		BankCh:Fire(true, "Deposit", { amount = amount, token = tostring(math.random(1, 999999)) })
		task.wait(1)
		if atmGui then
			BankCh:Fire(true, "ATMState", false)
			pcall(function()
				atmGui.Visible = false
			end)
		end
		result = ("stored %d"):format(amount)
	end)
	if not ok then
		warn("[ryujin] depositExcess error: " .. tostring(err))
		result = "error"
	end
	if myToken == FLY.token then
		if bot.enabled and bot.working then
			-- Job loop is running: stay hovering underground, the loop picks
			-- up from here (flyStop would drop the character into the void)
			flyHold()
		else
			-- Manual deposit outside the loop: resurface at the ATM
			local r3 = flyTo(atm.part.Position + Vector3.new(0, 1.5, 0), true)
			if r3 ~= "cancelled" and r3 ~= "kicked" then
				waitArrive(15, true)
			end
			if myToken == FLY.token then
				flyStop()
			end
		end
	end
	releaseFlightControl(myToken)
	return result
end

local function collectPromptParts(folder)
	local out = {}
	local f = JA:FindFirstChild(folder)
	if not f then return out end
	for _, part in ipairs(f:GetDescendants()) do
			if part:IsA("BasePart") or part:IsA("Model") then
				local pp = part:FindFirstChildWhichIsA("ProximityPrompt")
				if pp and pp.Enabled and part.Parent then
					local pos = part:IsA("BasePart") and part.Position or (part:FindFirstChild("HumanoidRootPart") and part.HumanoidRootPart.Position) or part:GetPivot().Position
					if pos and insideGangZone(pos.X, pos.Z) then continue end
					out[#out + 1] = { inst = part, prompt = pp, pos = pos }
				end
			end
		end
	return out
end

local function offerText(poster)
	local fallback = nil
	for _, s in ipairs(poster:GetDescendants()) do
		if s:IsA("SurfaceGui") then
			for _, t in ipairs(s:GetDescendants()) do
				if t:IsA("TextLabel") and t.Text ~= "" then
					local clean = t.Text:gsub("<[^>]+>", "")
					if t.Name == "Info" then
						return clean
					end
					fallback = fallback or clean
				end
			end
		end
	end
	return fallback
end

local function posterOf(cd)
	local p = cd.Parent
	if p and p.Name ~= "Trigger" then return p end
	return p and p.Parent
end

local function supportedJob(text)
	if not text then return false end
	local t = text:lower()
	if t:find("deliver") or t:find("milk") or t:find("trash") or t:find("bag") then
		return false
	end
	return t:find("dirt") or t:find("graffiti") or t:find("cat") or t:find("letter") or t:find("poster") or t:find("find")
end

-- Only Cat is enabled for now; the dropdown stays so more can be added later.
local ALL_JOBS = { "Cat (Find Item)" }

local function jobCategory(text)
	local t = (text or ""):lower()
	if t:find("dirt") then return "Dirt Cleaning" end
	if t:find("graffiti") then return "Graffiti" end
	if t:find("poster") then return "Poster Hanging" end
	if t:find("letter") or t:find("mail") then return "Letter Delivery" end
	if t:find("cat") or t:find("find") then return "Cat (Find Item)" end
	return nil
end

local function jobtypeCategory(jt)
	local t = (jt or ""):lower()
	if t:find("dirt") then return "Dirt Cleaning" end
	if t:find("graffiti") then return "Graffiti" end
	if t:find("poster") then return "Poster Hanging" end
	if t:find("letter") or t:find("mail") then return "Letter Delivery" end
	if t:find("find") then return "Cat (Find Item)" end
	return nil
end

bot = { enabled = false, working = false, jobsDone = 0, cashEarned = 0, stuckCount = 0, safe = false, enabledJobs = table.clone(ALL_JOBS), height = 7 }

getgenv().__botState = bot
getgenv().__flyState = FLY
getgenv().__kickState = KICK
getgenv().__gangState = { base = GANG_BASE, zones = GANG_ZONES }

-- Kick watcher: while the job bot is flying, a teleport larger than one frame
-- of flight (server kicks non-gang players out of the gang base) aborts flight.
-- The character hovers in place instead of calling flyStop: it is usually
-- underground at cruise depth, and dropping gravity would send it into the void.
run.Heartbeat:Connect(function()
	local root = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	local watching = bot.enabled and FLY.enabled and FLY.bv and root ~= nil
	if not watching then
		KICK._root = root
		KICK._last = root and root.Position or nil
		return
	end
	if root ~= KICK._root then
		KICK._root = root
		KICK._last = root.Position
		return
	end
	local last = KICK._last
	KICK._last = root.Position
	if last and (root.Position - last).Magnitude > 60 then
		-- REVIEW MODE: detection only logs; no KICK.detected, no hover, no recovery
		warn("[ryujin] KICK DETECTED (review - no action): teleport " .. string.format("%.0f", (root.Position - last).Magnitude) .. " studs at " .. string.format("%.1f,%.1f", last.X, last.Z))
	end
end)

local function jobEnabled(jt)
	local c = jobtypeCategory(jt)
	return c ~= nil and (not bot.enabledJobs or table.find(bot.enabledJobs, c) ~= nil)
end

local function allPosterCandidates()
	local out = {}
	for _, groupName in ipairs({ "Job Borders", "Quest Borders", "Bounty Jobs" }) do
		local g = JA:FindFirstChild(groupName)
		if g then
			for _, border in ipairs(g:GetDescendants()) do
				if border:IsA("ClickDetector") then
					local poster = posterOf(border)
					local text = poster and offerText(poster) or nil
					local pos = poster and (poster:IsA("BasePart") and poster.Position or poster:GetPivot().Position) or border.Parent:GetPivot().Position
					if pos and insideGangZone(pos.X, pos.Z) then continue end
					out[#out + 1] = { cd = border, poster = poster, text = text, pos = pos }
				end
			end
		end
	end
	return out
end

local function isCovered(pt)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { lp.Character }
	local parts = workspace:GetPartBoundsInBox(CFrame.new(pt), Vector3.new(3, 2, 3), params)
	return #parts > 0
end

-- Climb back up to open air at the given XZ
local function surfaceOf(pos)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { lp.Character }
	local p = pos
	for _ = 1, 50 do
		local hit = workspace:Raycast(p + Vector3.new(0, 0.25, 0), Vector3.new(0, 60, 0), params)
		if not hit then
			return p.Y + 1
		end
		p = Vector3.new(p.X, hit.Position.Y + 4, p.Z)
	end
	return nil
end

-- Extra depth so the HEAD (not just root) stays underground
local CHARACTER_TOP = 2

undergroundOf = function(pos, maxDist)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { lp.Character }
	local height = (bot.height or 3) + CHARACTER_TOP
	local floorY = nil
	local hit = workspace:Raycast(pos + Vector3.new(0, 1, 0), Vector3.new(0, -60, 0), params)
	if hit then floorY = hit.Position.Y end
	if floorY then
		for _ = 1, 5 do
			local t = Vector3.new(pos.X, floorY - height, pos.Z)
			if isCovered(t + Vector3.new(0, 1, 0)) then
				if (t - pos).Magnitude <= maxDist then return t end
				local dir = (t - pos).Unit
				return pos + dir * maxDist
			end
			local down = workspace:Raycast(t + Vector3.new(0, 0.5, 0), Vector3.new(0, -60, 0), params)
			if not down then break end
			floorY = down.Position.Y
		end
	end
	local t = pos - Vector3.new(0, height, 0)
	if (t - pos).Magnitude <= maxDist then return t end
	return pos + (t - pos).Unit * maxDist
end

-- Does the segment (ax,az)-(bx,bz) intersect the axis-aligned rect on XZ?
local function segHitsRect(ax, az, bx, bz, x1, z1, x2, z2)
	local dx, dz = bx - ax, bz - az
	local t0, t1 = 0, 1
	local function clip(p, q)
		if p == 0 then return q >= 0 end
		local r = q / p
		if p < 0 then
			if r > t1 then return false end
			if r > t0 then t0 = r end
		else
			if r < t0 then return false end
			if r < t1 then t1 = r end
		end
		return true
	end
	return clip(-dx, ax - x1) and clip(dx, x2 - ax) and clip(-dz, az - z1) and clip(dz, z2 - az)
end

-- Waypoints to route around the gang base when a straight flight would cross
-- it. Returns a flat {x,z} (single corner) or {x,z,x,z} (adjacent corner pair)
-- list, or nil when the direct path is already clear.
local function baseDetour(ax, az, bx, bz)
	local b = GANG_BASE
	if not segHitsRect(ax, az, bx, bz, b.x1, b.z1, b.x2, b.z2) then return nil end
	-- Corners sit 5 studs beyond the expanded zone so insideGangZone
	-- (boundary-inclusive) never rejects the waypoint itself
	local m = b.margin + 5
	local corners = {
		{ b.x1 - m, b.z1 - m },
		{ b.x2 + m, b.z1 - m },
		{ b.x2 + m, b.z2 + m },
		{ b.x1 - m, b.z2 + m },
	}
	local best, bestLen = nil, math.huge
	local function legClear(x1, z1, x2, z2)
		if segHitsRect(x1, z1, x2, z2, b.x1, b.z1, b.x2, b.z2) then return false end
		if insideGangZone(x1, z1) or insideGangZone(x2, z2) then return false end
		return true
	end
	for _, c in ipairs(corners) do
		if legClear(ax, az, c[1], c[2]) and legClear(c[1], c[2], bx, bz) then
			local len = math.sqrt((c[1] - ax) ^ 2 + (c[2] - az) ^ 2) + math.sqrt((bx - c[1]) ^ 2 + (bz - c[2]) ^ 2)
			if len < bestLen then bestLen = len; best = { c[1], c[2] } end
		end
	end
	for i = 1, 4 do
		local c1 = corners[i]
		local c2 = corners[i % 4 + 1]
		if legClear(ax, az, c1[1], c1[2]) and legClear(c1[1], c1[2], c2[1], c2[2]) and legClear(c2[1], c2[2], bx, bz) then
			local len = math.sqrt((c1[1] - ax) ^ 2 + (c1[2] - az) ^ 2)
				+ math.sqrt((c2[1] - c1[1]) ^ 2 + (c2[2] - c1[2]) ^ 2)
				+ math.sqrt((bx - c2[1]) ^ 2 + (bz - c2[2]) ^ 2)
			if len < bestLen then bestLen = len; best = { c1[1], c1[2], c2[1], c2[2] } end
		end
	end
	return best
end

flyUndergroundTo = function(destPoint, ignoreCancel, token)
	local me = rootPos()
	if not me then
		local r0 = flyTo(destPoint, ignoreCancel)
		if r0 == "cancelled" then return "cancelled" end
		if r0 == "kicked" then return "kicked" end
		waitArrive(20, ignoreCancel)
		return "ok"
	end
	-- Dive to underground depth at current XZ first (no shallow clamp)
	local curFloor = undergroundOf(me, 100)
	local destFloor = undergroundOf(destPoint, 100)
	local cruiseY = math.min(curFloor and curFloor.Y or me.Y, destFloor and destFloor.Y or destPoint.Y)
	if token and token ~= FLY.token then return "superseded" end
	-- Step 1: dive straight down at current position
	local r1 = flyTo(Vector3.new(me.X, cruiseY, me.Z), ignoreCancel)
	if r1 == "cancelled" then return "cancelled" end
	if r1 == "kicked" then return "kicked" end
	r1 = waitArrive(15, ignoreCancel)
	if r1 == "cancelled" then return "cancelled" end
	if r1 == "kicked" then return "kicked" end
	if token and token ~= FLY.token then return "superseded" end
	-- Step 2: travel horizontally at safe underground depth, detouring around
	-- the gang base when the straight line would cross it
	local detour = baseDetour(me.X, me.Z, destPoint.X, destPoint.Z)
	if detour then
		for i = 1, #detour, 2 do
			local wx, wz = detour[i], detour[i + 1]
			local rw = flyTo(Vector3.new(wx, cruiseY, wz), ignoreCancel)
			if rw == "cancelled" then return "cancelled" end
			if rw == "kicked" then return "kicked" end
			rw = waitArrive(45, ignoreCancel)
			if rw == "cancelled" then return "cancelled" end
			if rw == "kicked" then return "kicked" end
			if token and token ~= FLY.token then return "superseded" end
		end
	end
	local r2 = flyTo(Vector3.new(destPoint.X, cruiseY, destPoint.Z), ignoreCancel)
	if r2 == "cancelled" then return "cancelled" end
	if r2 == "kicked" then return "kicked" end
	r2 = waitArrive(25, ignoreCancel)
	if r2 == "cancelled" then return "cancelled" end
	if r2 == "kicked" then return "kicked" end
	if token and token ~= FLY.token then return "superseded" end
	-- Step 3: adjust to exact destination depth
	local r3 = flyTo(destPoint, ignoreCancel)
	if r3 == "cancelled" then return "cancelled" end
	if r3 == "kicked" then return "kicked" end
	r3 = waitArrive(10, ignoreCancel)
	if r3 == "cancelled" then return "cancelled" end
	if r3 == "kicked" then return "kicked" end
	return "ok"
end

-- Cancel the active job through the jobs GUI channel and wait for it to clear.
local function cancelActiveJob()
	if jobs.activejob then
		JobsCh:Fire(true, "Cancel")
	end
	local t0 = os.clock()
	while jobs.activejob and os.clock() - t0 < 12 do
		task.wait(0.5)
	end
end

local function claimJob()
	waitFlightIdle()
	local cands = allPosterCandidates()
	local supported = {}
	local me = rootPos()
	for _, c in ipairs(cands) do
		if supportedJob(c.text) and jobEnabled(jobCategory(c.text)) then
			supported[#supported + 1] = c
		end
	end
	if #supported == 0 then
		return "no supported offer"
	end
	table.sort(supported, function(a, b)
		return me and (a.pos - me).Magnitude < (b.pos - me).Magnitude or false
	end)
	local target = supported[1]
	if bot.safe then
		local rf = flyUndergroundTo(undergroundOf(target.pos, 12) or target.pos)
		if rf == "cancelled" then return "cancelled" end
		if rf == "kicked" then return "kicked" end
	else
		local rf = flyTo(target.pos + Vector3.new(0, 1, 0))
		if rf == "cancelled" then return "cancelled" end
		if rf == "kicked" then return "kicked" end
	end
	-- Board offers can rotate while flying; verify before clicking
	local fresh = offerText(target.poster) or target.text
	if not (supportedJob(fresh) and jobEnabled(jobCategory(fresh))) then
		return "offer changed, re-claiming"
	end
	for i = 1, 6 do
		if jobs.activejob then
			return "claimed"
		end
		local p = rootPos()
		if not p or (p - target.pos).Magnitude > 15 then
			local rw = waitArrive(8)
			if rw == "cancelled" then return "cancelled" end
			if rw == "kicked" then return "kicked" end
		end
		fireclickdetector(target.cd, 0, "MouseClick")
		task.wait(0.12)
	end
	return "claim failed"
end

local function goBackToBoard()
	waitFlightIdle()
	local cands = allPosterCandidates()
	local me = rootPos()
	if not me then return end
	local best = nil
	for _, c in ipairs(cands) do
		if supportedJob(c.text) and jobEnabled(jobCategory(c.text)) then
			if not best or (c.pos - me).Magnitude < (best.pos - me).Magnitude then
				best = c
			end
		end
	end
	if best then
		if bot.safe then
			local r = flyUndergroundTo(undergroundOf(best.pos, 12) or best.pos)
			if r == "kicked" or r == "cancelled" then return end
		else
			local r = flyTo(best.pos + Vector3.new(0, 1, 0))
			if r == "cancelled" or r == "kicked" then return end
			waitArrive(20)
		end
	end
end

local function safeTarget(folder, best)
	local maxDist = math.max(2, (best.prompt.MaxActivationDistance or 6) - 1)
	local pos = best.pos
	if folder == "Dirts" then
		return undergroundOf(pos, maxDist) or pos
	elseif folder == "Posters" or folder == "Graffiti" then
		local part = best.inst
		if part:IsA("BasePart") then
			local dir = -part.CFrame.LookVector
			dir = Vector3.new(dir.X, 0, dir.Z)
			if dir.Magnitude > 0.1 then
				dir = dir.Unit
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				params.FilterDescendantsInstances = { part, lp.Character }
				local hit = workspace:Raycast(pos, dir * 8, params)
				if hit then
					local t = hit.Position + dir * 1.5
					if (t - pos).Magnitude <= maxDist then return t end
				end
			end
		end
	end
	return pos
end

local function runPromptJob(folder)
	outcome.last = nil
	local done, total = progressOf(jobs.activejob)
	local tried = {}
	local lastSeen = done
	local lastChange = os.clock()
	while jobs.activejob and bot.enabled do
		local d, t = progressOf(jobs.activejob)
		if d ~= lastSeen then
			lastSeen = d
			lastChange = os.clock()
			done, total = d, t
			tried = {}
		end
		if total > 0 and done >= total then return "complete" end
		if os.clock() - lastChange > 20 then return "no progress" end
		local targets = collectPromptParts(folder)
		local me = rootPos()
		local best = nil
		for _, t in ipairs(targets) do
			if not tried[t.inst] then
				if not best or (me and (t.pos - me).Magnitude < (best.pos - me).Magnitude) then
					best = t
				end
			end
		end
		if not best then
			-- Wait longer for targets to spawn before giving up
			for _wait = 1, 5 do
				task.wait(1)
				local d2, t2 = progressOf(jobs.activejob)
				if t2 > 0 and d2 >= t2 then return "complete" end
				targets = collectPromptParts(folder)
				if #targets > 0 then break end
			end
			if #targets == 0 then
				if os.clock() - lastChange > 20 then return "no progress" end
				return "no targets left"
			end
			-- Found targets after waiting, continue the loop
			continue
		end
		local targetPos = bot.safe and safeTarget(folder, best) or best.pos
		waitFlightIdle()
		if bot.safe then
			local rf = flyUndergroundTo(targetPos)
			if rf == "cancelled" then return "cancelled" end
			if rf == "kicked" then return "kicked" end
		else
			local rf = flyTo(targetPos)
			if rf == "cancelled" then return "cancelled" end
			if rf == "kicked" then return "kicked" end
			local rw = waitArrive(8)
			if rw == "cancelled" then return "cancelled" end
			if rw == "kicked" then return "kicked" end
		end
		flyHold()
		local got = false
		for r = 1, 3 do
			fireproximityprompt(best.prompt)
			task.wait(0.9)
			local d2, t2 = progressOf(jobs.activejob)
			if d2 > lastSeen then
				lastSeen = d2
				lastChange = os.clock()
				done, total = d2, t2
				got = true
				break
			end
		end
		if not got then
			tried[best.inst] = true
		end
	end
	if outcome.last == "success" then return "complete" end
	return "job ended"
end

local function runFindItem()
	outcome.last = nil
	local done, total = progressOf(jobs.activejob)
	local lastSeen = done
	local lastChange = os.clock()
	while jobs.activejob and bot.enabled do
		local d, t = progressOf(jobs.activejob)
		if d ~= lastSeen then
			lastSeen = d
			lastChange = os.clock()
			done, total = d, t
		end
		if total > 0 and done >= total then return "complete" end
		if os.clock() - lastChange > 25 then return "no progress" end
		local cats = {}
		for _, dd in ipairs(workspace.Ignore.VFX:GetDescendants()) do
			if dd:IsA("ClickDetector") and dd.MaxActivationDistance == 12 then
				cats[#cats + 1] = dd
			end
		end
		if #cats == 0 then
			task.wait(0.5)
			local d2, t2 = progressOf(jobs.activejob)
			if t2 > 0 and d2 >= t2 then return "complete" end
			if os.clock() - lastChange > 25 then return "no progress" end
			task.wait(1.5)
			local d3, t3 = progressOf(jobs.activejob)
			if d3 == lastSeen then
				return "no cats spawned"
			end
			lastSeen, done, total = d3, d3, t3
		end
		local passProgress = false
		for _, cd in ipairs(cats) do
			local target = cd.Parent:IsA("BasePart") and cd.Parent.Position or cd.Parent:GetPivot().Position
			waitFlightIdle()
			if bot.safe then
				local rf = flyUndergroundTo(undergroundOf(target, math.max(2, cd.MaxActivationDistance - 1)) or target)
				if rf == "cancelled" then return "cancelled" end
				if rf == "kicked" then return "kicked" end
			else
				local rf = flyTo(target + Vector3.new(0, 1, 0))
				if rf == "cancelled" then return "cancelled" end
				if rf == "kicked" then return "kicked" end
				local rw = waitArrive(8)
				if rw == "cancelled" then return "cancelled" end
				if rw == "kicked" then return "kicked" end
			end
			flyHold()
			task.wait(0.2)
			-- Keep clicking the cat for up to ~5s; the first click sometimes
			-- misses and the job would otherwise sit waiting underground
			local t0 = os.clock()
			local got = false
			while os.clock() - t0 < 5 do
				fireclickdetector(cd, 0, "MouseClick")
				task.wait(0.7)
				local d2, t2 = progressOf(jobs.activejob)
				if d2 > lastSeen then
					lastSeen = d2
					lastChange = os.clock()
					done, total = d2, t2
					got = true
					passProgress = true
					break
				end
				if not jobs.activejob then break end
			end
			if got and not jobs.activejob then break end
		end
		-- A full pass over every cat with no progress means the job is stuck;
		-- cancel it and let the main loop claim a new one
		if #cats > 0 and not passProgress and jobs.activejob and os.clock() - lastChange > 5 then
			Library:Notify({ Title = "Ryujin Jobs", Description = "Cat job stuck - cancelling", Time = 3 })
			JobsCh:Fire(true, "Cancel")
			local t0 = os.clock()
			while jobs.activejob and os.clock() - t0 < 8 do
				task.wait(0.5)
			end
			if not jobs.activejob then return "cancelled" end
		end
		task.wait(0.5)
	end
	if outcome.last == "success" then return "complete" end
	return "job ended"
end

local function executeJob(aj)
	local jt = (aj.jobtype or ""):lower()
	if not jobEnabled(jt) then
		return "job disabled"
	end
	if jt:find("dirt") then
		return "dirt: " .. runPromptJob("Dirts")
	elseif jt:find("graffiti") then
		return "graffiti: " .. runPromptJob("Graffiti")
	elseif jt:find("letter") or jt:find("mail") then
		return "letters: " .. runPromptJob("LettersLocations")
	elseif jt:find("poster") then
		return "posters: " .. runPromptJob("Posters")
	elseif jt:find("find") then
		return "finditem: " .. runFindItem()
	end
	return "unsupported: " .. tostring(aj.jobtype)
end

local train = { enabled = false, working = false, method = "Situp", stopStam = 30, resumeStam = 80, stopFat = 90, resumeFat = 80, reps = 0, sessions = 0 }

getgenv().__trainState = train

-- Machine training: walk/fly to a MachineTraining-tagged machine, hold E on its
-- ProximityPrompt, then answer the same Circle/Square minigames as tools.
local machine = { enabled = false, working = false, method = "Pull Up", stopStam = 30, resumeStam = 45, stopFat = 90, resumeFat = 80, reps = 0, sessions = 0 }

getgenv().__machineState = machine

-- Boxing gloves training (underground Dojo Room): the gloves are a CONSUMABLE
-- tool. Equipping and firing ToolActivated consumes the pair and grants a
-- temporary BoxingGloves tag; when the tag expires the pair is gone, so the
-- bot re-buys from the nearest in-room Buyable (within 35 studs, like the
-- game's own macro) and re-equips. Bags stay intact - only gloves disappear.
local boxing = { enabled = false, working = false, stopStam = 30, resumeStam = 45, stopFat = 90, resumeFat = 80, reps = 0, sessions = 0, pairs = 0, depth = 11, lying = true }

getgenv().__boxingState = boxing

local MACHINE_NAMES = {
	["Pull Up"] = "Pullup",
	["Bench Press"] = "Benchpress",
	["Barbell Squat"] = "Barbellsquat",
	["Treadmill"] = "Treadmill",
	["Weight Twists"] = "Weight Twist",
}

local MACHINE_NEEDS_WEIGHT = { Benchpress = true, Barbellsquat = true, ["Weight Twist"] = true }

local trainContainer = nil
local function trainingsUI()
	if trainContainer and trainContainer.Parent then return trainContainer end
	local hud = lp.PlayerGui:FindFirstChild("HUD")
	if not hud then return nil end
	local sec = hud:FindFirstChild("Secondary")
	if not sec then return nil end
	trainContainer = sec:FindFirstChild("Trainings")
	return trainContainer
end

local function getStamina()
	local ok, st = pcall(Utility.GetStamina, lp)
	if ok and type(st) == "number" then return st end
	local a = lp:GetAttribute("Stamina")
	if type(a) == "number" then return a end
	return nil
end

local function getMaxStamina()
	local ok, mx = pcall(Utility.GetMaxStamina, lp)
	if ok and type(mx) == "number" then return mx end
	local a = lp:GetAttribute("MaxStamina")
	if type(a) == "number" then return a end
	return nil
end

-- Fatigue is already 0..100 in the player data: the game's own macro gates
-- on raw >= 90 to stop training, wakes at <= 0, and Lofi refuses to sell a
-- massage below 50. (An old bug multiplied by 100, so real 79 read as 7930
-- and recovery kept falsely triggering.) Do NOT scale it.
local function getFatigue()
	local ok, data = pcall(Utility.SnipeData, lp)
	if ok and typeof(data) == "Instance" then
		local f = data:FindFirstChild("Fatigue")
		if f and f:IsA("NumberValue") then return f.Value end
	end
	return nil
end

local function equipAndActivate(toolName)
	local char = lp.Character
	if not char then return "no character" end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return "no humanoid" end
	local tool = char:FindFirstChild(toolName) or lp.Backpack:FindFirstChild(toolName)
	if not tool then return "missing tool: " .. toolName end
	Utility.UnequipTools(char)
	task.wait()
	hum:EquipTool(tool)
	task.wait()
	WarpSig:Fire("Tools", "ToolActivated")
	local t0 = os.clock()
	while os.clock() - t0 < 6 do
		if CollectionService:HasTag(char, "Training") then
			return "active"
		end
		task.wait(0.1)
	end
	return "tag never appeared"
end

local function answerMinigames(container, counter)
	counter = counter or train
	-- Square: the answer is fixed when the square spawns (Square module sets
	-- currAnswer once and never changes it) - fire the reply immediately.
	-- (The square may flash red on the client because no real key is pressed,
	-- but the server accepts the answer - sessions stay alive and reps/ST
	-- keep counting. Do NOT destroy or touch the element: that ends the
	-- server session.)
	local sq = container:FindFirstChild("Square")
	if sq and not sq:GetAttribute("Used") then
		sq:SetAttribute("Used", true)
		pcall(function() TrainingsCh:Fire(true, "Reply", SquareMod.currAnswer) end)
		counter.reps += 1
	end
	-- Circle: the ring shrinks over 0.45s; the reply only counts after that,
	-- so wait for age >= 0.45 before pressing.
	local ci = container:FindFirstChild("Circle")
	if ci and not ci:GetAttribute("Used") then
		local age = tick() - (ci:GetAttribute("spawnedAt") or tick())
		if age >= 0.45 then
			ci:SetAttribute("Used", true)
			pcall(function() TrainingsCh:Fire(true, "Reply", CircleMod.currAnswer) end)
			counter.reps += 1
		end
	end
end

-- One training session: equip tool, activate, answer minigames until the server
-- ends the session (stamina out / movement / lost tag), or we stop for stamina.
-- Pushup is click-style: the server ends the session quickly and expects
-- ToolActivated re-fired every ~0.25s while untagged (same as the built-in macro).
local function runTrainingSession()
	local char = lp.Character
	if not char then return "no character" end
	local container = trainingsUI()
	local start = equipAndActivate(train.method)
	if start ~= "active" then return start end
	local clickStyle = (train.method == "Pushup")
	local lastFire = os.clock()
	local t0 = os.clock()
	while train.enabled and os.clock() - t0 < 600 do
		local mx = getMaxStamina()
		local st = getStamina()
		if not mx or not st then
			task.wait(0.3)
			mx = getMaxStamina()
			st = getStamina()
		end
		if mx and st and st / mx * 100 < train.stopStam then
			return "stamina low, resting"
		end
		local fat = getFatigue()
		if fat and fat >= train.stopFat then
			return "fatigue high, resting"
		end
		if clickStyle then
			if not CollectionService:HasTag(char, "Training") then
				if os.clock() - lastFire >= 0.25 then
					WarpSig:Fire("Tools", "ToolActivated")
					train.reps += 1
					lastFire = os.clock()
				end
			end
		else
			if not CollectionService:HasTag(char, "Training") then
				return "session ended"
			end
			if container then
				answerMinigames(container)
			end
		end
		task.wait(clickStyle and 0.05 or 0.03)
	end
	return "session timeout"
end

task.spawn(function()
	while STATE.alive() do
		if train.enabled and not train.working then
			train.working = true
			local ok, err = pcall(function()
				while train.enabled do
					-- Wait for fatigue to drop before a new session. Fatigue
					-- only falls while sleeping or massaged, so no timeout:
					-- running a session at high fatigue grants nothing.
					local fat = getFatigue()
					if fat and fat >= train.resumeFat then
						Library:Notify({ Title = "Train", Description = ("Fatigue %.0f%% - recovering (%s)"):format(fat, recover.method), Time = 4 })
						if recoverFatigue(train, "Train") == "disabled" then break end
					end
					-- Wait for stamina to recover before starting a new session
					local mx = getMaxStamina()
					local st = getStamina()
					if mx and st and st / mx * 100 < train.resumeStam then
						local t0 = os.clock()
						while train.enabled and os.clock() - t0 < 240 do
							mx = getMaxStamina()
							st = getStamina()
							if mx and st and st / mx * 100 >= train.resumeStam then
								break
							end
							task.wait(2)
						end
					end
					local r = runTrainingSession()
					if r:find("cancelled") then
						waitFlightIdle()
					else
						train.sessions += 1
						Library:Notify({ Title = "Train", Description = ("%s | %d total reps"):format(r, train.reps), Time = 3 })
					end
					task.wait(1.5)
				end
			end)
			if not ok then
				warn("[ryujin] train loop error: " .. tostring(err))
			end
			train.working = false
		end
		task.wait(0.5)
	end
end)

-- ============ MACHINE TRAIN ============
-- Find the nearest machine of the selected type, get within prompt range, hold
-- E to start, then answer Circle/Square minigames exactly like tool training.
-- Weight machines (Benchpress/Barbell Squat/Weight Twist) open a weight picker
-- FIRST: the server sets the character's "pickingWeight" attribute and only
-- grants the Training tag once a valid weight is answered. The option list is
-- pushed on the Trainings channel as "DisplayWeights" (a table whose numeric
-- entries carry .Required; .Type says which stat gates them, "UM"/"LM"). The
-- server-side validation matches the picker GUI: an option is usable iff
-- stat >= opt.Required, and the pick is the option's index in that list.
local machineWeightList = nil
local machineWeightType = "UM"
local _weightsCaptured = false
local function captureWeights()
	if _weightsCaptured then return end
	_weightsCaptured = true
	TrainingsCh:Connect(function(p1, p2, p3)
		if p1 ~= "DisplayWeights" then return end
		if type(p2) == "table" then
			machineWeightList = p2
			machineWeightType = (type(p2.Type) == "string" and p2.Type) or (type(p3) == "string" and p3) or "UM"
			getgenv().__lastWeights = { list = p2, at = os.clock() }
			warn(("[ryujin] weight picker options (%s): %d"):format(machineWeightType, #p2))
		end
	end)
end

local function playerStat(name)
	local ok, data = pcall(Utility.SnipeData, lp)
	if ok and typeof(data) == "Instance" then
		local stats = data:FindFirstChild("Statistics")
		if stats then
			local v = stats:FindFirstChild(name)
			if v and v:IsA("NumberValue") then return v.Value end
		end
	end
	return nil
end

-- Wait for the picker's option list, then answer with the heaviest index the
-- character's gating stat qualifies for; "No Weight" (Required==0) is the last
-- fallback. If the server already accepted the session (tag up) or never
-- pushed a list, answer the game's own default (1) after the wait. Returns
-- "cancelled" only when the character vanished.
local function pickWeightFromPicker(char)
	captureWeights()
	local t0 = os.clock()
	while os.clock() - t0 < 12 do
		if CollectionService:HasTag(char, "Training") then
			return "tagged directly"
		end
		if char:GetAttribute("pickingWeight") and machineWeightList then break end
		task.wait(0.1)
	end
	if not machineWeightList then
		warn("[ryujin] no DisplayWeights list received, answering default 1")
		TrainingsCh:Fire(true, "PickedWeight", 1)
		pcall(function() require(RS.Modules.Client.GUIs.Miscs.trainingweights).ToggleGui(false) end)
		return "fallback"
	end
	local st = playerStat(machineWeightType)
	local bestIdx, bestReq = nil, -1
	for i, opt in ipairs(machineWeightList) do
		if type(opt) == "table" then
			local req = type(opt.Required) == "number" and opt.Required or 0
			if req > 0 then
				if st and st >= req and req > bestReq then
					bestIdx, bestReq = i, req
				end
			elseif bestIdx == nil then
				bestIdx = i
			end
		end
	end
	local idx = bestIdx or 1
	warn(("[ryujin] picking weight index %d (req %s, %s stat %s)"):format(idx, tostring(bestReq), machineWeightType, tostring(st)))
	TrainingsCh:Fire(true, "PickedWeight", idx)
	pcall(function() require(RS.Modules.Client.GUIs.Miscs.trainingweights).ToggleGui(false) end)
	return tostring(idx)
end

local function nearestMachine()
	local me = rootPos()
	if not me then return nil end
	local want = MACHINE_NAMES[machine.method]
	local best, bestD = nil, math.huge
	for _, m in ipairs(CollectionService:GetTagged("MachineTraining")) do
		if m.Name == want then
			local pos = m:GetPivot().Position
			local d = (pos - me).Magnitude
			if d < bestD then
				bestD = d
				best = m
			end
		end
	end
	return best
end

-- Start one machine session: E-press the machine prompt, wait for the Training
-- tag, then answer minigames until the server ends the session or stamina runs out.
local function runMachineSession()
	local char = lp.Character
	if not char then return "no character" end
	local m = nearestMachine()
	if not m then return "no machine nearby: " .. machine.method end
	local pp = m:FindFirstChildWhichIsA("ProximityPrompt", true)
	local part = pp and pp.Parent
	if not pp or not part then return "machine has no prompt" end
	local target = part:IsA("BasePart") and part.Position or m:GetPivot().Position
	local spot = target + (target - (rootPos() or target)).Unit * math.min(2, (target - (rootPos() or target)).Magnitude)
	-- Fly just beside the machine part so the prompt is within range
	local rf = flyTo(target + Vector3.new(0, 0.5, 0), false)
	if rf == "cancelled" then return "cancelled" end
	local rw = waitArrive(15)
	if rw == "cancelled" then return "cancelled" end
	if rw == "kicked" then return "kicked" end
	-- Start via the prompt: engine honors InputHoldBegin, so hold E for the
	-- prompt's HoldDuration. fireproximityprompt first, keypress as fallback.
	fireproximityprompt(pp)
	local t0 = os.clock()
	local started = false
	while os.clock() - t0 < 5 do
		if CollectionService:HasTag(char, "Training") or char:GetAttribute("pickingWeight") then
			started = true
			break
		end
		task.wait(0.1)
	end
	if not started then
		keypress(69)
		task.wait((pp.HoldDuration or 1) + 0.4)
		keyrelease(69)
		t0 = os.clock()
		while os.clock() - t0 < 6 do
			if CollectionService:HasTag(char, "Training") or char:GetAttribute("pickingWeight") then
				started = true
				break
			end
			task.wait(0.1)
		end
	end
	if not started then
		return "tag never appeared"
	end
	-- Weight machines (Benchpress/Barbell Squat/Weight Twist) pop the weight
	-- picker: answer the heaviest index the character's stat qualifies for so
	-- the server accepts it and grants the Training tag.
	if MACHINE_NEEDS_WEIGHT[m.Name] and not CollectionService:HasTag(char, "Training") then
		local pw = pickWeightFromPicker(char)
		if pw == "cancelled" then return "cancelled" end
	end
	t0 = os.clock()
	while os.clock() - t0 < 8 do
		if CollectionService:HasTag(char, "Training") then break end
		task.wait(0.1)
	end
	if not CollectionService:HasTag(char, "Training") then
		return "tag never appeared after weight pick"
	end
	local container = trainingsUI()
	local t1 = os.clock()
	local reason = "session timeout"
	while machine.enabled and os.clock() - t1 < 600 do
		local mx = getMaxStamina()
		local st = getStamina()
		if not mx or not st then
			task.wait(0.3)
			mx = getMaxStamina()
			st = getStamina()
		end
		if mx and st and st / mx * 100 < machine.stopStam then
			reason = "stamina low, resting"
			break
		end
		local fat = getFatigue()
		if fat and fat >= machine.stopFat then
			reason = "fatigue high, resting"
			break
		end
		if not CollectionService:HasTag(char, "Training") then
			reason = "session ended"
			break
		end
		if container then
			answerMinigames(container, machine)
		end
		task.wait(0.03)
	end
	-- Land so we don't hover mid-air during rest or after the user toggles off;
	-- the next session (if any) re-flies. The early "cancelled"/"kicked" returns
	-- happen above, so whoever owns flight there is left untouched.
	flyStop()
	return reason
end

task.spawn(function()
	while STATE.alive() do
		if machine.enabled and not machine.working then
			machine.working = true
			local ok, err = pcall(function()
				while machine.enabled do
					local fat = getFatigue()
					if fat and fat >= machine.resumeFat then
						Library:Notify({ Title = "Machine Train", Description = ("Fatigue %.0f%% - recovering (%s)"):format(fat, recover.method), Time = 4 })
						if recoverFatigue(machine, "Machine Train") == "disabled" then break end
					end
					local mx = getMaxStamina()
					local st = getStamina()
					if mx and st and st / mx * 100 < machine.resumeStam then
						local t0 = os.clock()
						while machine.enabled and os.clock() - t0 < 240 do
							mx = getMaxStamina()
							st = getStamina()
							if mx and st and st / mx * 100 >= machine.resumeStam then
								break
							end
							task.wait(2)
						end
					end
					local r = runMachineSession()
					if r:find("cancelled") then
						waitFlightIdle()
					else
						machine.sessions += 1
						Library:Notify({ Title = "Machine Train", Description = ("%s | %d total reps"):format(r, machine.reps), Time = 3 })
					end
					task.wait(1.5)
				end
			end)
			if not ok then
				warn("[ryujin] machine train loop error: " .. tostring(err))
			end
			machine.working = false
		end
		task.wait(0.5)
	end
end)

-- ============ BOXING GLOVES TRAIN ============
-- Consumable-tool training: buy Boxing Gloves from a Buyable (goose dojo area
-- on the mountain only — the underground Dojo Room is gang-restricted and the
-- AutoMacro purchase remote needs the gamepass), equip + ToolActivated to
-- consume a pair and get the BoxingGloves tag, then punch a PunchingBag with
-- M1 until the tag expires and a fresh pair is needed. Mirrors the game's own
-- macro (Core2.macro) minus the gamepass bits.
-- Purchase goes through the Buyable's ClickDetector (server-owned, 25 studs)
-- via fireclickdetector, which replicates a real click to the server — the
-- same path a normal player uses to buy without the Auto Macro gamepass.
local GOOSE_ANCHOR = Vector3.new(-318, 134, 1226)
local GOOSE_RADIUS = 350

local function gooseAnchor()
	local goose = workspace.Ignore.NPCs.Miscs:FindFirstChild("Goose")
	if goose then
		local p = goose:GetPivot().Position
		return Vector3.new(p.X, p.Y, p.Z)
	end
	return GOOSE_ANCHOR
end

local function inGooseArea(pos)
	return (pos - gooseAnchor()).Magnitude <= GOOSE_RADIUS
end

local function nearestBoxingBuyable()
	local me = rootPos()
	if not me then return nil end
	local best, bestD = nil, math.huge
	for _, b in ipairs(CollectionService:GetTagged("Buyable")) do
		if b.Name == "Boxing Gloves" and inGooseArea(b:GetPivot().Position) then
			local d = (b:GetPivot().Position - me).Magnitude
			if d < bestD then bestD = d; best = b end
		end
	end
	return best
end

local function nearestBoxingBag()
	local me = rootPos()
	if not me then return nil end
	local best, bestD = nil, math.huge
	for _, b in ipairs(CollectionService:GetTagged("PunchingBag")) do
		if inGooseArea(b:GetPivot().Position) then
			local d = (b:GetPivot().Position - me).Magnitude
			if d < bestD then bestD = d; best = b end
		end
	end
	return best
end

local function boxingGlovesTool()
	local char = lp.Character
	if char then
		local t = char:FindFirstChild("Boxing Gloves")
		if t then return t end
	end
	return lp.Backpack:FindFirstChild("Boxing Gloves")
end

local function boxingEquipAndConsume()
	local char = lp.Character
	if not char then return "no character" end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return "no humanoid" end
	local tool = boxingGlovesTool()
	if not tool then return "missing gloves" end
	Utility.UnequipTools(char)
	task.wait()
	hum:EquipTool(tool)
	task.wait()
	WarpSig:Fire("Tools", "ToolActivated")
	local t0 = os.clock()
	while os.clock() - t0 < 6 do
		if CollectionService:HasTag(char, "BoxingGloves") then
			boxing.pairs += 1
			return "active"
		end
		task.wait(0.1)
	end
	return "tag never appeared"
end

local function boxingBuyGloves()
	local b = nearestBoxingBuyable()
	if not b then return "no glove buyable" end
	local me = rootPos()
	if me and (me - b:GetPivot().Position).Magnitude > 20 then
		local rf = flyUndergroundTo(b:GetPivot().Position + Vector3.new(0, 1, 0))
		if rf == "cancelled" then return "cancelled" end
		if rf == "kicked" then return "kicked" end
	end
	local cd = b:FindFirstChild("ClickDetector")
	if not cd then return "no click detector" end
	fireclickdetector(cd, 1, "MouseClick")
	local t0 = os.clock()
	while os.clock() - t0 < 6 do
		if boxingGlovesTool() then return "bought" end
		task.wait(0.2)
	end
	return "purchase failed"
end

-- Lay the character flat (spine horizontal) with the FACE pointing at the bag,
-- so the whole body sits underground while the M1 direction keeps hitting the
-- bag above. The server credits a punch from the character's facing, so the
-- LookVector must go toward the bag - a plain lookAt * -90deg pitch would
-- aim the face INTO the floor. Built with fromMatrix: -Z (look) at the bag,
-- +Y (spine) kept horizontal. Re-applied fast because the humanoid's state
-- machine tries to stand the character back up (AutoRotate fights it too).
local function boxingLyingPose(spot)
	local char = lp.Character
	if not char then return end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local f = (spot - root.Position).Unit
	if f.Magnitude < 0.001 then return end
	local h = Vector3.new(1, 0, 0)
	if math.abs(h:Dot(f)) > 0.7 then h = Vector3.new(0, 0, 1) end
	h = (h - f * h:Dot(f)).Unit
	local cf = CFrame.fromMatrix(root.Position, h:Cross(-f), h, -f)
	root.CFrame = cf
end

local function runBoxingSession()
	local char = lp.Character
	if not char then return "no character" end
	-- Roblox streaming: the goose dojo bags may not be loaded if the character
	-- spawned far away. Fly to the goose anchor first so the bags + buyable
	-- stream in, then re-scan for a bag.
	local bag = nearestBoxingBag()
	if not bag then
		local rf0 = flyUndergroundTo(gooseAnchor())
		if rf0 == "cancelled" then return "cancelled" end
		if rf0 == "kicked" then return "kicked" end
		local t0 = os.clock()
		while boxing.enabled and os.clock() - t0 < 15 do
			bag = nearestBoxingBag()
			if bag then break end
			task.wait(0.5)
		end
		if not bag then return "no bag in goose dojo" end
	end
	local spot = bag:GetPivot().Position
	local parkY = spot.Y - boxing.depth
	local rf = flyUndergroundTo(Vector3.new(spot.X, parkY, spot.Z))
	if rf == "cancelled" then return "cancelled" end
	if rf == "kicked" then return "kicked" end
	-- Ensure a pair is active before punching
	if not CollectionService:HasTag(char, "BoxingGloves") then
		if not boxingGlovesTool() then
			local buy = boxingBuyGloves()
			if buy ~= "bought" then return buy end
		end
		local act = boxingEquipAndConsume()
		if act ~= "active" then return act end
	end
	local lastM1 = os.clock()
	local lastPose = 0
	local hum0 = char:FindFirstChildOfClass("Humanoid")
	local savedAutoRotate = hum0 and hum0.AutoRotate
	if hum0 then hum0.AutoRotate = false end
	local t1 = os.clock()
	local reason = "session timeout"
	while boxing.enabled and os.clock() - t1 < 600 do
		if boxing.lying and os.clock() - lastPose >= 0.1 then
			boxingLyingPose(spot)
			lastPose = os.clock()
		end
		local mx = getMaxStamina()
		local st = getStamina()
		if not mx or not st then
			task.wait(0.3)
			mx = getMaxStamina()
			st = getStamina()
		end
		if mx and st and st / mx * 100 < boxing.stopStam then
			reason = "stamina low, resting"
			break
		end
		local fat = getFatigue()
		if fat and fat >= boxing.stopFat then
			reason = "fatigue high, resting"
			break
		end
		-- The pair was consumed: re-buy + re-equip (mirrors the game macro's
		-- 5s glove check; the tag expiring means the gloves are gone)
		if not CollectionService:HasTag(char, "BoxingGloves") then
			if not boxingGlovesTool() then
				local buy = boxingBuyGloves()
				if buy == "cancelled" then return "cancelled" end
				if buy == "kicked" then return "kicked" end
				if buy ~= "bought" then
					reason = buy
					break
				end
			end
			local act = boxingEquipAndConsume()
			if act ~= "active" then
				reason = act
				break
			end
		end
		-- Punch: keep the Combat tool equipped (SnipeTool), fire M1 at the
		-- macro's cadence while tagged and not in a tool-training session.
		local combat = lp.Backpack:FindFirstChild("Combat")
		if combat and combat.Parent ~= char then
			Utility.UnequipTools(char)
			task.wait()
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum then hum:EquipTool(combat) end
			task.wait()
		end
		if os.clock() - lastM1 >= 0.255 then
			if CollectionService:HasTag(char, "BoxingGloves") and not CollectionService:HasTag(char, "Training") then
				WarpSig:Fire("Combat", "M1")
				boxing.reps += 1
				lastM1 = os.clock()
			end
		end
		task.wait(0.05)
	end
	if hum0 then hum0.AutoRotate = savedAutoRotate ~= nil and savedAutoRotate or true end
	return reason
end

task.spawn(function()
	while STATE.alive() do
		if boxing.enabled and not boxing.working then
			boxing.working = true
			local ok, err = pcall(function()
				while boxing.enabled do
					local fat = getFatigue()
					if fat and fat >= boxing.resumeFat then
						Library:Notify({ Title = "Boxing Train", Description = ("Fatigue %.0f%% - recovering (%s)"):format(fat, recover.method), Time = 4 })
						if recoverFatigue(boxing, "Boxing Train") == "disabled" then break end
					end
					local mx = getMaxStamina()
					local st = getStamina()
					if mx and st and st / mx * 100 < boxing.resumeStam then
						local t0 = os.clock()
						while boxing.enabled and os.clock() - t0 < 240 do
							mx = getMaxStamina()
							st = getStamina()
							if mx and st and st / mx * 100 >= boxing.resumeStam then
								break
							end
							task.wait(2)
						end
					end
					local r = runBoxingSession()
					if r:find("cancelled") then
						waitFlightIdle()
					else
						boxing.sessions += 1
						Library:Notify({ Title = "Boxing Train", Description = ("%s | %d total hits"):format(r, boxing.reps), Time = 3 })
					end
					task.wait(1.5)
				end
			end)
			if not ok then
				warn("[ryujin] boxing train loop error: " .. tostring(err))
			end
			boxing.working = false
		end
		task.wait(0.5)
	end
end)

-- ============ ROADWORK: fully-underground training route test ============
local rwFolder2 = workspace.Ignore.Interactables.Roadworks
local Saitama = workspace.Ignore.NPCs["Important NPCs"].Saitama
local DialogueCh = Warp.Client("Dialogue")
rwState = { running = false, phase = "idle", bought = false, cps = 0, cash0 = 0, ag0 = 0, st0 = 0, rwLog = {} }
getgenv().__rwState = rwState

rwConfig = {
	enabled = false,
	route = "Short Route",
	speed = 120,
	-- Flip: hang the character upside down for the whole run so the head and
	-- name tag stay under the road even on checkpoints that force the pop.
	flip = false,
	-- Pop depth: how far the HRP parks below the street at each checkpoint.
	-- This rig is compact (head top +1.7 above HRP) and roadwork cubes sit
	-- with their bottom flush against the road, so the registration bound
	-- parks the HRP at road level and head+shoulders briefly top it on most
	-- checkpoints no matter what this says. It only bites on cubes mounted
	-- high enough that street-height parks the body under the surface.
	height = 3,
}
getgenv().__rwConfig = rwConfig

local RW_ANSWERS = {
	["Short Route"] = "Short run (₩1500).",
	["Long Route"] = "Long run (₩4000).",
}

local rwStatusLabel = nil

local function rwFriendly(msg)
	if msg:find("RUN STARTED", 1, true) then return "Run started" end
	if msg:find("purchase confirmed", 1, true) then return "Route bought" end
	if msg:find("REGISTERED", 1, true) then return "Checkpoint reached" end
	if msg:find("never registered", 1, true) then return "Checkpoint missed" end
	if msg:find("chase done", 1, true) then return "Checkpoints done" end
	if msg:find("no checkpoints registered", 1, true) then return "No checkpoints found" end
	if msg:find("run complete", 1, true) then return "Run done, heading back" end
	if msg:find("resurfacing", 1, true) then return "Coming back to the surface" end
	if msg:find("resurfaced", 1, true) then return "Back on the surface" end
	if msg:find("baseline cash", 1, true) then return "Starting run" end
	if msg:find("diving from", 1, true) then return "Heading underground" end
	if msg:find("cruising to", 1, true) then return "Flying to Saitama" end
	if msg:find("hover final", 1, true) then return "Arriving at Saitama" end
	if msg:find("prompt absent", 1, true) then return "Moving closer to Saitama" end
	if msg:find("settle burst", 1, true) then return "Adjusting position" end
	if msg:find("dialogue:", 1, true) then return "Talking to Saitama" end
	if msg:find("final cash", 1, true) then return "Run finished" end
	if msg:find("route set to", 1, true) then return "Route selected" end
	if msg:find("ERROR", 1, true) then return "Something went wrong" end
	return msg
end

local function rwLog(msg)
	table.insert(rwState.rwLog, ("[%s] %s"):format(os.date("%H:%M:%S"), msg))
	if #rwState.rwLog > 200 then table.remove(rwState.rwLog, 1) end
	warn("[rw] " .. msg)
	if rwStatusLabel then
		pcall(function() rwStatusLabel:SetText(rwFriendly(msg)) end)
	end
end

local function rwCash()
	local ok, data = pcall(Utility.SnipeData, lp)
	if not ok or typeof(data) ~= "Instance" then return nil end
	local c = data:FindFirstChild("Cash")
	return c and c:IsA("NumberValue") and c.Value or nil
end

local function rwStat(name)
	local ok, data = pcall(Utility.SnipeData, lp)
	if not ok or typeof(data) ~= "Instance" then return nil end
	local s = data:FindFirstChild("Statistics")
	return s and s:FindFirstChild(name) and s[name].Value or nil
end

local function rwBillboard()
	for _, p in ipairs(rwFolder2:GetDescendants()) do
		if p:IsA("BasePart") and p:FindFirstChild("LocationBill") then
			return p
		end
	end
	return nil
end

-- Street height from up-casts only (down-rays hit buildings). The Roadworks
-- folder and the player's own body are excluded so billboard poles never
-- register as "street" (they sit at 98.7-102.4 next to a 98.2 road). h1 may
-- hit the walking surface itself or a slab underside; if it hits a surface,
-- h2 (from just above it) picks out a separate higher deck if one exists.
local rwStreetParams = nil
local function rwStreetAt(x, z)
	if not rwStreetParams then
		rwStreetParams = RaycastParams.new()
		rwStreetParams.FilterType = Enum.RaycastFilterType.Exclude
	end
	local filters = { rwFolder2 }
	local c = lp.Character
	if c then filters[#filters + 1] = c end
	rwStreetParams.FilterDescendantsInstances = filters
	local h1 = workspace:Raycast(Vector3.new(x, 86, z), Vector3.new(0, 220, 0), rwStreetParams)
	if not h1 then return nil, nil end
	local slabB = h1.Position.Y
	local street = slabB
	local h2 = workspace:Raycast(Vector3.new(x, math.max(86, slabB + 1.2), z), Vector3.new(0, 220, 0), rwStreetParams)
	if h2 then
		local s2 = h2.Position.Y
		if s2 > slabB + 0.5 and s2 <= slabB + 12 then street = s2 end
	end
	return street, slabB
end

local function rwDialText()
	local dlg = lp.PlayerGui.HUD.Main:FindFirstChild("Dialogue")
	return dlg and dlg:FindFirstChild("Dialogue") and dlg.Dialogue.Text or ""
end

local function rwDialOptions()
	local dlg = lp.PlayerGui.HUD.Main:FindFirstChild("Dialogue")
	if not dlg then return {} end
	local out = {}
	local opts = dlg:FindFirstChild("Options")
	if opts then
		for _, b in ipairs(opts:GetChildren()) do
			if b:IsA("ImageButton") or b:IsA("TextButton") then
				local t = b:FindFirstChild("OptionText")
				if t and t.Visible then
					-- The GUI displays "N. Display" but fires the raw Display
					-- string; strip the numbering prefix so we send what the
					-- server actually matches.
					local clean = t.Text:gsub("^%d+%.%s*", "")
					out[#out + 1] = clean
				end
			end
		end
	end
	return out
end

-- Get within the prompt spawn range. The fly's Heartbeat zeroes velocity under
-- 2.5 studs, so small nudges never move; instead drive the character into the
-- landing band (93.82, 96.32] by bursting up to 96.32 from below - every stop
-- inside that band has dist-to-prompt 7.1-7.6 and the head never comes closer
-- than 2 studs below the street (101.9).
local function rwSettlePrompt(sp)
	local h = rootPos()
	if not h then return false end
	if h.Y > 93.5 then
		flyTo(Vector3.new(sp.Position.X, 90.5, sp.Position.Z), true)
		waitArrive(5, true)
	end
	for _, tgt in ipairs({ 96.6, 97.2 }) do
		flyTo(Vector3.new(sp.Position.X, tgt, sp.Position.Z), true)
		waitArrive(5, true)
		h = rootPos()
		local d = h and (h - sp.Position).Magnitude or 999
		rwLog(("settle burst %.1f: y=%.2f dist=%.2f"):format(tgt, h and h.Y or -1, d))
		if d <= 7.6 then return true end
	end
	return false
end

-- Opens/targets the Saitama dialogue and buys the Short run using the live
-- option text; returns "bought" or a failure reason.
local function rwPrompt()
	local p = Saitama:FindFirstChild("DialogueProx", true) or Saitama:FindFirstChildWhichIsA("ProximityPrompt", true)
	if p then return p end
	-- the prompt may live outside the model; hunt near the NPC
	local sp = Saitama:FindFirstChild("HumanoidRootPart")
	if not sp then return nil end
	for _, probe in ipairs(workspace.Ignore.NPCs:GetDescendants()) do
		if probe:IsA("ProximityPrompt") and (probe.Parent:IsA("BasePart") or probe.Parent:IsA("Model")) then
			local pos = probe.Parent:IsA("BasePart") and probe.Parent.Position or probe.Parent:GetPivot().Position
			if (pos - sp.Position).Magnitude < 3 then return probe end
		end
	end
	return nil
end

local function rwBuy()
	local sp = Saitama:FindFirstChild("HumanoidRootPart")
	if not sp then return "no Saitama root" end
	local prompt = rwPrompt()
	if not prompt then
		rwLog("prompt absent; settling closer")
		if not rwSettlePrompt(sp) then return "prompt never spawned" end
		prompt = rwPrompt()
		if not prompt then return "prompt still absent" end
	end
	-- Always re-trigger the prompt: the server-side dialogue session
	-- (ActivePlayers[Character]) is destroyed when the character moves or
	-- respawns, so a stale open GUI fires into a dead session. A fresh
	-- InputHoldBegin recreates the session and shows page 1.
	-- The engine only honors the prompt hold while Saitama is in the camera's
	-- view; underground the default camera looks down at the character, so the
	-- NPC above is off-screen and the hold is silently ignored. Force the
	-- camera below the character's feet looking up at Saitama, and keep it
	-- there through the whole hold. Stop the moment the hold ends: a camera
	-- that keeps moving while the dialogue is open deactivates the prompt and
	-- the server drops the answer.
	local cam = workspace.CurrentCamera
	local aimLoop = task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < 2.5 do
			local me = rootPos()
			if me then
				cam.CFrame = CFrame.lookAt(me + Vector3.new(0, -3, 0), sp.Position)
			end
			task.wait(0.05)
		end
	end)
	DialogueCh:Fire(true, "Cleanup")
	task.wait(0.4)
	prompt:InputHoldBegin()
	task.wait(1.2)
	prompt:InputHoldEnd()
	task.cancel(aimLoop)
	local function waitOptions(timeout)
		local t0 = os.clock()
		while os.clock() - t0 < timeout do
			local t = rwDialText()
			local opts = rwDialOptions()
			if #opts > 0 then return opts, t end
			task.wait(0.25)
		end
		return {}, rwDialText()
	end
	-- Page 1: intro. The server keys answers by the raw DialoguesList
	-- strings, so fire those exactly (this is the flow that has always
	-- worked) and only use the GUI text to confirm the page state.
	local opts, text = waitOptions(5)
	rwLog(("dialogue: %q options=[%s]"):format(text, table.concat(opts, " | ")))
	if #opts == 0 then return "dialogue did not open: " .. tostring(text) end
	DialogueCh:Fire(true, "Resume", { Answer = "Hey, can you show me some training routes?" })
	-- The server can take several seconds to process the answer and the GUI
	-- types the text out (0.02s/char) before rendering options, so poll long
	-- and detect the transition by the page-2 text, not by option count.
	local t0 = os.clock()
	opts, text = {}, rwDialText()
	while os.clock() - t0 < 25 do
		text = rwDialText()
		if text:match("long or short route") then break end
		task.wait(0.25)
	end
	rwLog(("dialogue: %q options=[%s]"):format(text, table.concat(rwDialOptions(), " | ")))
	if not text:match("long or short route") then
		return "page 2 did not open: " .. tostring(text)
	end
	t0 = os.clock()
	while os.clock() - t0 < 10 do
		if #rwDialOptions() > 0 then break end
		task.wait(0.25)
	end
	local answer = RW_ANSWERS[rwConfig.route]
	if not answer then return "unknown route: " .. tostring(rwConfig.route) end
	local cash0 = rwCash()
	DialogueCh:Fire(true, "Resume", { Answer = answer })
	local t0 = os.clock()
	while os.clock() - t0 < 8 do
		local c = rwCash()
		if c < cash0 - 100 then
			rwLog("purchase confirmed: cash " .. tostring(cash0) .. " -> " .. tostring(c))
			DialogueCh:Fire(true, "Cleanup")
			task.wait(0.5)
			return "bought"
		end
		task.wait(0.25)
	end
	return "purchase not confirmed: cash still " .. tostring(rwCash())
end

-- Chase billboards. Depth ladder: start street-9 (head 5.4 under the road),
-- step up 0.4 per retry, hard ceiling street-7.4 (head 3.8 under). Never above.
local function rwChase()
	local cps = 0
	local last = nil
	local t0 = os.clock()
	while os.clock() - t0 < 300 do
		if not rwState.running then return cps, "stopped" end
		local b = rwBillboard()
		if not b then return cps, "ended" end
		if not last then
			rwLog("RUN STARTED on " .. b.Name)
		end
		if b ~= last then
			last = b
			cps += 1
			local cx, cz = b.Position.X, b.Position.Z
			-- Transit at depth: never set a target at pop altitude, or the
			-- character cruises the whole way visible. Dive first, then
			-- travel low.
			local me = rootPos()
			if me then
				flyTo(Vector3.new(me.X, 91.5, me.Z), true)
				waitArrive(12, true)
			end
			flyTo(Vector3.new(cx, 91.5, cz), true)
			waitArrive(30, true)
			-- Pop: the server registers when the HRP is within ~8 studs of
			-- the cube center (7.7 works, 8.7 doesn't), so the deepest
			-- registering park is cube.Y - 7.6. This rig is compact (head
			-- center +1.4, top +1.67, torso at HRP), and the cube's bottom is
			-- flush with the road, so the registration bound parks the HRP at
			-- road level and head+shoulders briefly top it no matter what
			-- height says. rwConfig.height only bites on cubes mounted higher
			-- than 7.6 above the road, where street-height parks the body
			-- below the surface. The park is clamped so it can never go deep
			-- enough to miss registration.
			local street, slabB = rwStreetAt(cx, cz)
			local popY = b.Position.Y - 7.6
			local parkY = popY
			if street and slabB then
				local desired = street - rwConfig.height
				parkY = math.max(desired, popY)
				rwLog(("cp %d (%s): street=%.1f height=%.1f parkY=%.1f (cube %.1f)"):format(cps, b.Name, street, rwConfig.height, parkY, b.Position.Y))
			end
			flyTo(Vector3.new(cx, parkY + 2.5, cz), true)
			waitArrive(8, true)
			local registered = false
			local w0 = os.clock()
			while os.clock() - w0 < 6 do
				if not rwState.running then return cps, "stopped" end
				local nb = rwBillboard()
				if not nb then
					-- final checkpoint: the server removes the billboard the
					-- moment it registers, so count it and let the dive-back
					-- below run instead of returning here with the head up
					registered = true
					break
				end
				if nb ~= b then
					registered = true
					local p = rootPos()
					rwLog(("cp %d (%s) REGISTERED in %.1fs hrpY=%.1f head=%.1f"):format(cps, b.Name, os.clock() - w0, p and p.Y or 0, p and (p.Y + 3.6) or 0))
					break
				end
				task.wait(0.2)
			end
			-- Dive back immediately either way
			flyTo(Vector3.new(cx, 91.5, cz), true)
			waitArrive(10, true)
			if not registered then
				rwLog(("cp %d: never registered at pop y=%.1f"):format(cps, popY))
			end
		else
			task.wait(0.5)
		end
	end
	return cps, "timeout"
end

-- Bring the player back above ground at the current spot: climb to the
-- street surface, then drop the fly so they stand normally. Only call while
-- holding flight control.
local function rwResurface()
	local me = rootPos()
	if not me then return end
	local street = rwStreetAt(me.X, me.Z)
	local targetY = street and street + 1.0 or 105
	rwLog(("resurfacing: y=%.1f -> %.1f"):format(me.Y, targetY))
	flyTo(Vector3.new(me.X, targetY, me.Z), true)
	waitArrive(15, true)
	flyStop()
	rwLog("resurfaced")
end

-- One roadwork cycle: dive, cruise to Saitama, buy the selected route, chase
-- every checkpoint fully underground, then loop back to Saitama for the next
-- one. Runs until rwConfig.enabled goes false, which also resurfaces.
local function rwRunLoop()
	if rwState.running then return "already running" end
	rwState.running = true
	rwState.phase = "prep"
	rwState.rwLog = {}
	local myToken = nil
	local savedSpeed = nil
	task.spawn(function()
		local ok, err = pcall(function()
			local me = rootPos()
			if not me then error("no character") end
			waitFlightIdle()
			myToken = takeFlightControl()
			savedSpeed = FLY.speed
			FLY.speed = rwConfig.speed
			while rwConfig.enabled do
				rwState.bought = false
				rwState.cps = 0
				rwState.cash0 = rwCash() or 0
				rwState.ag0 = rwStat("AG") or 0
				rwState.st0 = rwStat("ST") or 0
				rwLog(("baseline cash=%.1f AG=%.3f ST=%.3f"):format(rwState.cash0, rwState.ag0, rwState.st0))
				me = rootPos()
				if not me then error("no character") end
				rwState.phase = "dive"
				rwLog(("diving from y=%.1f to 91"):format(me.Y))
				flyTo(Vector3.new(me.X, 91, me.Z), true)
				waitArrive(15, true)
				if not rwConfig.enabled then break end
				local sp = Saitama:FindFirstChild("HumanoidRootPart")
				if not sp then error("no Saitama root") end
				rwState.phase = "cruise"
				rwLog(("cruising to Saitama (%.0f, %.0f) at y=91"):format(sp.Position.X, sp.Position.Z))
				flyTo(Vector3.new(sp.Position.X, 91, sp.Position.Z), true)
				waitArrive(60, true)
				if not rwConfig.enabled then break end
				rwState.phase = "hover"
				flyTo(Vector3.new(sp.Position.X, 94.4, sp.Position.Z), true)
				waitArrive(8, true)
				if not rwConfig.enabled then break end
				if not rwSettlePrompt(sp) then
					error("could not get within prompt range")
				end
				local h = rootPos()
				rwLog(("hover final y=%.2f dist-to-prompt=%.2f"):format(h.Y, (h - sp.Position).Magnitude))
				rwState.phase = "buy"
				local got = rwBuy()
				if got ~= "bought" then
					error("buy failed: " .. got)
				end
				rwState.bought = true
				rwState.phase = "chase"
				local cps, how = rwChase()
				rwState.cps = cps
				rwLog(("chase done: cps=%d how=%s"):format(cps, how))
				Library:Notify({
					Title = "Roadwork " .. rwConfig.route,
					Description = ("cps=%d cash=%.0f AG=%.2f"):format(cps, rwCash() or 0, rwStat("AG") or 0),
					Time = 4,
				})
				if cps == 0 then
					rwLog("no checkpoints registered; giving up this cycle")
					break
				end
				if rwConfig.enabled then
					rwLog("run complete, returning to Saitama")
				end
			end
		end)
		if not ok then rwLog("ERROR: " .. tostring(err)) end
		if myToken and myToken == FLY.token then
			if rwConfig.enabled then
				-- stopped by an error while still enabled: park in place
				flyHold()
			else
				rwResurface()
			end
		end
		if savedSpeed then FLY.speed = savedSpeed end
		releaseFlightControl(myToken)
		rwState.phase = "done"
		rwState.running = false
		rwLog(("final cash=%.1f AG=%.3f ST=%.3f"):format(rwCash() or -1, rwStat("AG") or -1, rwStat("ST") or -1))
	end)
	return "started"
end

getgenv().__rwRunLoop = rwRunLoop
getgenv().__rwRunTest = rwRunLoop

-- ============ FATIGUE RECOVERY: Lofi massage ============
-- When a training automation stops for high fatigue, the bot cruises
-- underground to Lofi, buys a ₩10,000 massage through the NPC dialogue (the
-- same prompt hold + camera aim + raw Display answers as the Saitama
-- roadwork dialog, which is left untouched), rests until fatigue drains to
-- ~0, then comes back and resumes the automation. The hospital bed cluster
-- was rejected: it sits inside the gang-base zone and trips the gang kick.
recover = { method = "Lofi" }
getgenv().__recoverState = recover

local LOFI_ANCHOR = Vector3.new(804, 128, 772)

-- Generic NPC prompt finder (same logic rwPrompt uses for Saitama).
local function npcPrompt(npc)
	local p = npc:FindFirstChild("DialogueProx", true) or npc:FindFirstChildWhichIsA("ProximityPrompt", true)
	if p then return p end
	local sp = npc:FindFirstChild("HumanoidRootPart")
	if not sp then return nil end
	for _, probe in ipairs(workspace.Ignore.NPCs:GetDescendants()) do
		if probe:IsA("ProximityPrompt") and (probe.Parent:IsA("BasePart") or probe.Parent:IsA("Model")) then
			local pos = probe.Parent:IsA("BasePart") and probe.Parent.Position or probe.Parent:GetPivot().Position
			if (pos - sp.Position).Magnitude < 3 then return probe end
		end
	end
	return nil
end

-- Lofi massage: open the dialogue with the camera aimed from below so the
-- prompt hold is honored (exactly like rwBuy), then answer with the raw
-- Display strings. Returns "started" once the server accepted, else a reason.
local function lofiMassage()
	local lofi = workspace.Ignore.NPCs:FindFirstChild("Lofi", true)
	if not lofi then return "no Lofi NPC" end
	local sp = lofi:FindFirstChild("HumanoidRootPart")
	if not sp then return "no Lofi root" end
	local prompt = npcPrompt(lofi)
	if not prompt then return "no Lofi prompt" end
	local cam = workspace.CurrentCamera
	local aimLoop = task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < 2.5 do
			local me = rootPos()
			if me then
				cam.CFrame = CFrame.lookAt(me + Vector3.new(0, -3, 0), sp.Position)
			end
			task.wait(0.05)
		end
	end)
	DialogueCh:Fire(true, "Cleanup")
	task.wait(0.4)
	prompt:InputHoldBegin()
	task.wait(1.2)
	prompt:InputHoldEnd()
	task.cancel(aimLoop)
	local function waitOptions(timeout)
		local t0 = os.clock()
		while os.clock() - t0 < timeout do
			local opts = rwDialOptions()
			if #opts > 0 then return opts, rwDialText() end
			task.wait(0.25)
		end
		return {}, rwDialText()
	end
	local opts, text = waitOptions(5)
	if #opts == 0 then return "dialogue did not open: " .. tostring(text) end
	DialogueCh:Fire(true, "Resume", { Answer = "What can you do for me?" })
	local t0 = os.clock()
	while os.clock() - t0 < 25 do
		text = rwDialText()
		if text:find("right ways to touch you", 1, true) then break end
		task.wait(0.25)
	end
	if not text:find("right ways to touch you", 1, true) then
		return "page 2 did not open: " .. tostring(text)
	end
	t0 = os.clock()
	while os.clock() - t0 < 10 do
		if #rwDialOptions() > 0 then break end
		task.wait(0.25)
	end
	DialogueCh:Fire(true, "Resume", { Answer = "That sounds good, I'll take a massage. (₩10,000)" })
	t0 = os.clock()
	while os.clock() - t0 < 10 do
		text = rwDialText()
		if text:find("lay down on this table", 1, true) then
			DialogueCh:Fire(true, "Cleanup")
			return "started"
		end
		if text:find("currently full", 1, true) then return "no free massage beds" end
		if text:find("enough money", 1, true) then return "not enough cash (₩10,000 needed)" end
		if text:find("no fatigue", 1, true) then return "fatigue too low for massage" end
		task.wait(0.25)
	end
	return "massage not confirmed: " .. tostring(text)
end

-- Sleep until fatigue drains to ~0, then get up via jump (the built-in macro
-- wakes the same way). Returns "rested", "disabled" or a failure reason.
local function restUntilRested(ctrl)
	if not ctrl.enabled then return "disabled" end
	local t0 = os.clock()
	while ctrl.enabled and os.clock() - t0 < 25 do
		if CollectionService:HasTag(lp.Character, "Sleeping") then break end
		task.wait(0.5)
	end
	if not ctrl.enabled then return "disabled" end
	if not CollectionService:HasTag(lp.Character, "Sleeping") then
		return "did not fall asleep"
	end
	t0 = os.clock()
	while ctrl.enabled and os.clock() - t0 < 900 do
		local fat = getFatigue()
		if fat and fat <= 1 then break end
		if not CollectionService:HasTag(lp.Character, "Sleeping") then
			-- Woke up mid-rest: try to fall back asleep if still tired
			local still = getFatigue()
			if still and still > 1 then
				WarpSig:Fire("Movement", "AttemptUseBed")
			end
		end
		task.wait(5)
	end
	local g0 = os.clock()
	while ctrl.enabled and CollectionService:HasTag(lp.Character, "Sleeping") and os.clock() - g0 < 15 do
		WarpSig:Fire("Movement", "Jump")
		task.wait(0.5)
	end
	if not ctrl.enabled then return "disabled" end
	local fat = getFatigue()
	return (fat and fat <= 1) and "rested" or "still tired"
end

-- One recovery trip: cruise underground to the spot, rest until fatigue ~0,
-- cruise back to where training happens and surface there. Returns "rested",
-- "disabled" or a failure reason for the caller to retry.
local function doRecoveryTrip(ctrl)
	local method = recover.method
	if not method then return "none" end
	local start = rootPos()
	if not start then return "no character" end
	waitFlightIdle()
	if not ctrl.enabled then return "disabled" end
	local myToken = takeFlightControl()
	local result = "rested"
	local ok, err = pcall(function()
		if method ~= "Lofi" then
			error("unknown recovery method: " .. tostring(method))
		end
		local rf = flyUndergroundTo(LOFI_ANCHOR + Vector3.new(0, 2.5, 0), true, myToken)
		if rf ~= "ok" then error(rf) end
		flyHold()
		local started = lofiMassage()
		if started ~= "started" then error(started) end
		-- Server lays the character on a massage bed: drop the fly so the
		-- body stays where the server puts it.
		flyStop()
		local res = restUntilRested(ctrl)
		if res ~= "rested" then error(res) end
	end)
	if not ok then
		result = "recovery failed: " .. tostring(err)
		warn("[ryujin] fatigue recovery: " .. tostring(err))
	end
	-- End where the automation expects: back at the training spot if it still
	-- runs, standing in place if the user switched it off mid-trip.
	if myToken == FLY.token then
		if ctrl.enabled then
			pcall(function()
				local rf = flyUndergroundTo(undergroundOf(start, 12), true, myToken)
				if rf == "ok" then
					local sy = surfaceOf(start)
					flyTo(Vector3.new(start.X, sy or start.Y, start.Z), true)
					waitArrive(15, true)
				end
			end)
		end
		if myToken == FLY.token then
			flyStop()
		end
	end
	releaseFlightControl(myToken)
	return result
end

-- Blocks until fatigue is below the resume threshold (or the automation is
-- disabled). Called by the training loops.
recoverFatigue = function(ctrl, title)
	while ctrl.enabled do
		local fat = getFatigue()
		if not fat or fat < ctrl.resumeFat then return "rested" end
		warn(("[ryujin] %s fatigue trigger: %.1f >= resume %.1f -> Lofi trip"):format(title, fat, ctrl.resumeFat))
		local r = doRecoveryTrip(ctrl)
		if r == "disabled" then return "disabled" end
		if r == "rested" then return "rested" end
		Library:Notify({ Title = title, Description = r, Time = 5 })
		task.wait(r:find("cash") and 45 or 10)
	end
	return "disabled"
end

local _logoIcon = nil
if getcustomasset then
	pcall(function()
		_logoIcon = getcustomasset("BHLogo.png")
	end)
end
_logoIcon = _logoIcon or 112247610295198

local Window = Library:CreateWindow({
	Title = "Bang Hub",
	Footer = "Ryujin Script",
	Icon = _logoIcon,
	IconSize = UDim2.fromOffset(28, 28),
	ToggleKeybind = Enum.KeyCode.LeftAlt,
})

Library:Notify({
	Title = "Bang Hub",
	Description = "Press Left Alt to show or hide the UI.",
	Time = 10,
})

task.spawn(function()
	while STATE.alive() do
		local holder = nil
		for _, d in ipairs(game.Players.LocalPlayer.PlayerGui:GetDescendants()) do
			if d:IsA("ImageLabel") and (d.Image or ""):find("BHLogo") then
				holder = d.Parent
				break
			end
		end
		if holder then
			local layout = holder:FindFirstChildOfClass("UIListLayout")
			if layout then
				layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
			end
			local pad = holder:FindFirstChildOfClass("UIPadding")
			if not pad then
				pad = Instance.new("UIPadding")
				pad.PaddingLeft = UDim.new(0, 8)
				pad.Parent = holder
			end
			break
		end
		task.wait(0.2)
	end
end)

local MainTab = Window:AddTab("Auto", "play")
local MiscTab = Window:AddTab("Misc", "settings")

local MiscCard = MiscTab:AddLeftGroupbox("Utility")
local afkState = { enabled = false }
local afkToggle = MiscCard:AddToggle("AntiAfk", {
	Text = "Anti-AFK",
	Default = false,
	Tooltip = "Presses an unused key every minute so the game never thinks you're away. Safe to use with training or jobs.",
})

afkToggle:OnChanged(function(state)
	afkState.enabled = state
	Library:Notify({ Title = "Anti-AFK", Description = state and "On" or "Off", Time = 2 })
end)

task.spawn(function()
	local VIM = game:GetService("VirtualInputManager")
	while STATE.alive() do
		if afkState.enabled then
			pcall(function()
				VIM:SendKeyEvent(true, Enum.KeyCode.F5, false, game)
				task.wait(0.1)
				VIM:SendKeyEvent(false, Enum.KeyCode.F5, false, game)
			end)
		end
		task.wait(60)
	end
end)

local ControlCard = MainTab:AddLeftGroupbox("Job Control")
local TrainCard = MainTab:AddLeftGroupbox("Train Control")
local RWCard = MainTab:AddLeftGroupbox("Roadwork Control")
local StatusCard = MainTab:AddRightGroupbox("Status")
local StatsCard = MainTab:AddRightGroupbox("Stats")
local MachineCard = MainTab:AddRightGroupbox("Machine Train Control")

-- Forward-declared: autoRWToggle's OnChanged (above) cross-disables the
-- Auto Job and Train toggles, which are created after this card.
local autoJobToggle
local trainToggle

local autoRWToggle = RWCard:AddToggle("AutoRW", {
	Text = "Auto Roadwork",
	Default = false,
	Tooltip = "Buys the selected route from Saitama, does every checkpoint while hidden underground, then returns to Saitama and repeats. Toggle off to stop and come back up.",
})
autoRWToggle:OnChanged(function(state)
	rwConfig.enabled = state
	if state then
		bot.enabled = false
		train.enabled = false
		pcall(function() autoJobToggle:Set(false) end)
		pcall(function() trainToggle:Set(false) end)
		flyStop()
		local r = rwRunLoop()
		if r ~= "started" then
			pcall(function() autoRWToggle:Set(false) end)
			rwLog(r)
		end
	else
		rwState.running = false
		task.spawn(function()
			while rwState.running do task.wait(0.2) end
			waitFlightIdle()
			if rwConfig.enabled then return end
			pcall(function()
				local me = rootPos()
				if not me then return end
				local myToken = takeFlightControl()
				if isCovered(me + Vector3.new(0, 1, 0)) then
					local sy = surfaceOf(me)
					if sy then
						rwLog(("resurfacing: y=%.1f -> %.1f"):format(me.Y, sy))
						flyTo(Vector3.new(me.X, sy, me.Z), true)
						waitArrive(15, true)
					end
				end
				flyStop()
				releaseFlightControl(myToken)
				rwLog("resurfaced")
			end)
		end)
	end
	Library:Notify({
		Title = "Auto Roadwork",
		Description = state and ("Started: " .. rwConfig.route) or "Stopped",
		Time = 2,
	})
end)

rwStatusLabel = RWCard:AddLabel({ Text = "Not running" })

local rwRouteDropdown = RWCard:AddDropdown("RWRoute", {
	Text = "Roadwork Type",
	Values = { "Short Route", "Long Route" },
	Default = rwConfig.route,
	Tooltip = "Short Route costs ₩1500 (Agility +6, Stamina +3). Long Route costs ₩4000 (Agility +12, Stamina +6.4).",
})
rwRouteDropdown:OnChanged(function(sel)
	rwConfig.route = tostring(sel)
	rwLog("route set to " .. tostring(sel))
end)

local rwSpeedSlider = RWCard:AddSlider("RWSpeed", {
	Text = "Travel Speed",
	Default = 120,
	Min = 16,
	Max = 250,
	Rounding = 0,
	Tooltip = "How fast the bot flies while doing roadwork.",
})
rwSpeedSlider:OnChanged(function(val)
	rwConfig.speed = val
	if rwState.running and FLY.enabled then
		FLY.speed = val
	end
end)

local rwHeightSlider = RWCard:AddSlider("RWHeight", {
	Text = "Travel Depth",
	Default = 3,
	Min = 0.5,
	Max = 6,
	Rounding = 1,
	Tooltip = "How far below the street the bot parks at each checkpoint. Deeper = more hidden, but too deep can stop checkpoints from counting.",
})
rwHeightSlider:OnChanged(function(val)
	rwConfig.height = val
end)

local rwFlipToggle = RWCard:AddToggle("RWFlip", {
	Text = "Flip Character",
	Default = false,
	Tooltip = "Turns the character upside down while roadwork is running, so the head and name tag stay under the road even at checkpoints that force the pop. Nothing else about the run changes.",
})
rwFlipToggle:OnChanged(function(state)
	rwConfig.flip = state
	Library:Notify({ Title = "Roadwork Flip", Description = state and "Upside down during run" or "Normal orientation", Time = 2 })
end)

autoJobToggle = ControlCard:AddToggle("AutoJob", {
	Text = "Auto Job",
	Default = false,
})

local acceptJobsDropdown = ControlCard:AddDropdown("AcceptJobs", {
	Text = "Accept Jobs",
	Values = ALL_JOBS,
	Multi = true,
	Default = table.clone(ALL_JOBS),
})

local farmTypeDropdown = ControlCard:AddDropdown("FarmType", {
	Text = "Farm Type",
	Values = { "Normal", "Underground" },
	Default = "Normal",
})

local tweenSpeedSlider = ControlCard:AddSlider("TweenSpeed", {
	Text = "Travel Speed (Default 120)",
	Default = 120,
	Min = 16,
	Max = 250,
	Rounding = 0,
	Tooltip = "How fast the bot flies when working on jobs.",
})

local tweenHeightSlider = ControlCard:AddSlider("TweenHeight", {
	Text = "Travel Depth (Default 7)",
	Default = 7,
	Min = 1,
	Max = 12,
	Rounding = 0,
	Tooltip = "How deep the bot flies underground while doing jobs. Lower = closer to the surface, higher = deeper down. Keep it low enough to reach the dirt spots.",
})

autoJobToggle:OnChanged(function(state)
	bot.enabled = state
	if state then
		train.enabled = false
		trainToggle:Set(false)
	end
	if not state then
		task.spawn(function()
			pcall(function()
				local me = rootPos()
				if me and FLY.enabled and isCovered(me + Vector3.new(0, 1, 0)) then
					local sy = surfaceOf(me)
					if sy then
						local myToken = takeFlightControl()
						flyTo(Vector3.new(me.X, sy, me.Z), true)
						waitArrive(15, true)
						if myToken == FLY.token then
							flyStop()
						end
						releaseFlightControl(myToken)
					end
				end
				flyStop()
			end)
		end)
	end
	warn("[ryujin] Auto Job -> " .. tostring(state) .. " (working=" .. tostring(bot.working) .. ")")
	Library:Notify({
		Title = "Auto Job",
		Description = state and "Bot started" or "Bot stopped",
		Time = 2,
	})
end)

acceptJobsDropdown:OnChanged(function(sel)
	local arr = {}
	if typeof(sel) == "table" then
		for k, v in pairs(sel) do
			local item = type(k) == "string" and k or type(v) == "string" and v
			if item then
				arr[#arr + 1] = item
			end
		end
	elseif sel then
		arr[#arr + 1] = sel
	end
	if #arr == 0 then
		arr = table.clone(ALL_JOBS)
	end
	bot.enabledJobs = arr
end)

farmTypeDropdown:OnChanged(function(sel)
	bot.safe = (sel == "Underground")
	Library:Notify({ Title = "Farm Type", Description = tostring(sel), Time = 2 })
	task.spawn(function()
		pcall(function()
			local me = rootPos()
			if not me then return end
			local myToken = takeFlightControl()
			if bot.safe then
				local r = flyUndergroundTo(undergroundOf(me, 12) or me, true, myToken)
				if r ~= "superseded" and myToken == FLY.token and not bot.enabled then
					flyHold()
				end
			else
				local sy = surfaceOf(me)
				if sy then
					flyTo(Vector3.new(me.X, sy, me.Z), true)
					waitArrive(15, true)
					if myToken == FLY.token then
						flyStop()
					end
				end
			end
			releaseFlightControl(myToken)
		end)
	end)
end)

tweenSpeedSlider:OnChanged(function(val)
	FLY.speed = val
end)

tweenHeightSlider:OnChanged(function(val)
	bot.height = val
end)

local autoBankToggle = ControlCard:AddToggle("AutoBank", {
	Text = "Auto Bank",
	Default = false,
	Tooltip = "After each job, puts extra cash in the nearest ATM so your cash never hits the 1M limit.",
})

local bankAtSlider = ControlCard:AddSlider("BankAt", {
	Text = "Bank When Cash Exceeds",
	Default = 100000,
	Min = 50000,
	Max = 300000,
	Rounding = 0,
	Tooltip = "When your cash goes above this, everything is stored in the nearest ATM. You then earn back up to this before banking again, so ATM trips are rare. Keep it below the 1M limit.",
})

autoBankToggle:OnChanged(function(state)
	autoBank.enabled = state
	if state then
		task.spawn(function()
			pcall(function()
				local bk = bankAccount()
				local unlocked = bk and bk:FindFirstChild("Unlocked") and bk.Unlocked.Value
				if not unlocked then
					autoBank.noAccountNotified = false
					depositExcess()
				end
			end)
		end)
	end
	Library:Notify({ Title = "Auto Bank", Description = state and "Auto bank on" or "Auto bank off", Time = 2 })
end)

bankAtSlider:OnChanged(function(val)
	autoBank.bankAt = val
end)

trainToggle = TrainCard:AddToggle("AutoTrain", {
	Text = "Auto Train",
	Default = false,
})

local trainMethodDropdown = TrainCard:AddDropdown("TrainMethod", {
	Text = "Training",
	Values = { "Situp", "Squat", "Pushup", "One Hand Pushups", "Jumping Rope", "Jumping Jacks", "Handstand Pushup" },
	Default = "One Hand Pushups",
	Tooltip = "Pick a workout. The bot equips the item, starts it once, and answers the circle/square mini-game for you. Pushups need the tool clicked repeatedly instead.",
})

local trainStopSlider = TrainCard:AddSlider("TrainStop", {
	Text = "Stop at Stamina %",
	Default = 30,
	Min = 5,
	Max = 90,
	Rounding = 0,
})

local trainResumeSlider = TrainCard:AddSlider("TrainResume", {
	Text = "Resume at Stamina %",
	Default = 80,
	Min = 10,
	Max = 100,
	Rounding = 0,
})

trainMethodDropdown:OnChanged(function(sel)
	train.method = sel or "One Hand Pushups"
	Library:Notify({ Title = "Training", Description = tostring(sel), Time = 2 })
end)

trainStopSlider:OnChanged(function(val)
	train.stopStam = val
end)

trainResumeSlider:OnChanged(function(val)
	train.resumeStam = val
end)

local trainStopFatSlider = TrainCard:AddSlider("TrainStopFat", {
	Text = "Stop at Fatigue %",
	Default = 90,
	Min = 10,
	Max = 100,
	Rounding = 0,
	Tooltip = "Fatigue builds while training and at 100% you stop gaining stats, so the bot ends a session once fatigue passes this.",
})

local trainResumeFatSlider = TrainCard:AddSlider("TrainResumeFat", {
	Text = "Resume at Fatigue %",
	Default = 80,
	Min = 5,
	Max = 95,
	Rounding = 0,
	Tooltip = "Fatigue only drops by sleeping or massage, so the bot waits between sessions (no timeout) until fatigue falls below this.",
})

trainStopFatSlider:OnChanged(function(val)
	train.stopFat = val
end)

trainResumeFatSlider:OnChanged(function(val)
	train.resumeFat = val
end)

-- Forward-declared: trainToggle's OnChanged (above) cross-disables the machine
-- and boxing toggles, which are created below.
local machineToggle
local boxingToggle

trainToggle:OnChanged(function(state)
	train.enabled = state
	if state then
		statsBase = readStats()
		bot.enabled = false
		autoJobToggle:Set(false)
		if machineToggle then
			pcall(function()
				machineToggle:SetValue(false)
			end)
		end
		if boxingToggle then
			pcall(function()
				boxingToggle:SetValue(false)
			end)
		end
		task.spawn(function()
			pcall(function()
				local me = rootPos()
				if me and FLY.enabled and isCovered(me + Vector3.new(0, 1, 0)) then
					local sy = surfaceOf(me)
					if sy then
						local myToken = takeFlightControl()
						flyTo(Vector3.new(me.X, sy, me.Z), true)
						waitArrive(15, true)
						if myToken == FLY.token then
							flyStop()
						end
						releaseFlightControl(myToken)
					end
				end
				flyStop()
			end)
		end)
	end
	warn("[ryujin] Auto Train -> " .. tostring(state) .. " (working=" .. tostring(train.working) .. ")")
	Library:Notify({
		Title = "Auto Train",
		Description = state and "Bot started" or "Bot stopped",
		Time = 2,
	})
end)

machineToggle = MachineCard:AddToggle("MachineTrain", {
	Text = "Auto Machine Train",
	Default = false,
	Tooltip = "Picks a machine, starts it, and answers the mini-game for you automatically.",
})

local machineMethodDropdown = MachineCard:AddDropdown("MachineMethod", {
	Text = "Machine Training",
	Values = { "Pull Up", "Bench Press", "Barbell Squat", "Treadmill", "Weight Twists" },
	Default = "Pull Up",
	Tooltip = "Pick a machine. The bot walks to it, presses E once to start, then answers the circle/square mini-game. Pull Up trains Upper Muscle and Stamina.",
})

local machineStopSlider = MachineCard:AddSlider("MachineStop", {
	Text = "Stop at Stamina %",
	Default = 30,
	Min = 5,
	Max = 90,
	Rounding = 0,
})

local machineResumeSlider = MachineCard:AddSlider("MachineResume", {
	Text = "Resume at Stamina %",
	Default = 45,
	Min = 10,
	Max = 100,
	Rounding = 0,
})

machineMethodDropdown:OnChanged(function(sel)
	machine.method = sel or "Pull Up"
	Library:Notify({ Title = "Machine Training", Description = tostring(sel), Time = 2 })
end)

machineStopSlider:OnChanged(function(val)
	machine.stopStam = val
end)

machineResumeSlider:OnChanged(function(val)
	machine.resumeStam = val
end)

local machineStopFatSlider = MachineCard:AddSlider("MachineStopFat", {
	Text = "Stop at Fatigue %",
	Default = 90,
	Min = 10,
	Max = 100,
	Rounding = 0,
	Tooltip = "Fatigue builds while training and at 100% you stop gaining stats, so the bot ends a session once fatigue passes this.",
})

local machineResumeFatSlider = MachineCard:AddSlider("MachineResumeFat", {
	Text = "Resume at Fatigue %",
	Default = 80,
	Min = 5,
	Max = 95,
	Rounding = 0,
	Tooltip = "Fatigue only drops by sleeping or massage, so the bot waits between sessions (no timeout) until fatigue falls below this.",
})

machineStopFatSlider:OnChanged(function(val)
	machine.stopFat = val
end)

machineResumeFatSlider:OnChanged(function(val)
	machine.resumeFat = val
end)

machineToggle:OnChanged(function(state)
	machine.enabled = state
	if state then
		statsBase = readStats()
		bot.enabled = false
		autoJobToggle:Set(false)
		if trainToggle then
			pcall(function()
				trainToggle:SetValue(false)
			end)
		end
		if boxingToggle then
			pcall(function()
				boxingToggle:SetValue(false)
			end)
		end
		task.spawn(function()
			pcall(function()
				local me = rootPos()
				if me and FLY.enabled and isCovered(me + Vector3.new(0, 1, 0)) then
					local sy = surfaceOf(me)
					if sy then
						local myToken = takeFlightControl()
						flyTo(Vector3.new(me.X, sy, me.Z), true)
						waitArrive(15, true)
						if myToken == FLY.token then
							flyStop()
						end
						releaseFlightControl(myToken)
					end
				end
				flyStop()
			end)
		end)
	end
	warn("[ryujin] Machine Train -> " .. tostring(state) .. " (working=" .. tostring(machine.working) .. ")")
	Library:Notify({
		Title = "Machine Train",
		Description = state and "Bot started" or "Bot stopped",
		Time = 2,
	})
end)

boxingToggle = TrainCard:AddToggle("BoxingTrain", {
	Text = "Auto Boxing",
	Default = false,
	Tooltip = "Trains hidden underground in the Dojo Room: buys Boxing Gloves when they run out, equips them, then punches the bags.",
})

local boxingStopSlider = TrainCard:AddSlider("BoxingStop", {
	Text = "Boxing Stop at Stamina %",
	Default = 30,
	Min = 5,
	Max = 90,
	Rounding = 0,
})

local boxingResumeSlider = TrainCard:AddSlider("BoxingResume", {
	Text = "Boxing Resume at Stamina %",
	Default = 45,
	Min = 10,
	Max = 100,
	Rounding = 0,
})

local boxingHeightSlider = TrainCard:AddSlider("BoxingHeight", {
	Text = "Boxing Height (studs below bag)",
	Default = 11,
	Min = 2,
	Max = 18,
	Rounding = 1,
	Tooltip = "How far below the bag the bot hides. Deeper = more hidden, but too deep and hits stop counting. 11 is the recommended setting.",
})

boxingStopSlider:OnChanged(function(val)
	boxing.stopStam = val
end)

boxingResumeSlider:OnChanged(function(val)
	boxing.resumeStam = val
end)

local boxingStopFatSlider = TrainCard:AddSlider("BoxingStopFat", {
	Text = "Boxing Stop at Fatigue %",
	Default = 90,
	Min = 10,
	Max = 100,
	Rounding = 0,
	Tooltip = "Fatigue builds while training and at 100% you stop gaining stats, so the bot ends a session once fatigue passes this.",
})

local boxingResumeFatSlider = TrainCard:AddSlider("BoxingResumeFat", {
	Text = "Boxing Resume at Fatigue %",
	Default = 80,
	Min = 5,
	Max = 95,
	Rounding = 0,
	Tooltip = "Fatigue only drops by sleeping or massage, so the bot waits between sessions (no timeout) until fatigue falls below this.",
})

boxingStopFatSlider:OnChanged(function(val)
	boxing.stopFat = val
end)

boxingResumeFatSlider:OnChanged(function(val)
	boxing.resumeFat = val
end)

boxingHeightSlider:OnChanged(function(val)
	boxing.depth = val
end)

boxingToggle:OnChanged(function(state)
	boxing.enabled = state
	if state then
		statsBase = readStats()
		bot.enabled = false
		autoJobToggle:Set(false)
		if trainToggle then
			pcall(function()
				trainToggle:SetValue(false)
			end)
		end
		if machineToggle then
			pcall(function()
				machineToggle:SetValue(false)
			end)
		end
	end
	warn("[ryujin] Boxing Train -> " .. tostring(state) .. " (working=" .. tostring(boxing.working) .. ")")
	Library:Notify({
		Title = "Boxing Train",
		Description = state and "Bot started" or "Bot stopped",
		Time = 2,
	})
end)

local statusJobsLabel = StatusCard:AddLabel({ Text = "Jobs completed: 0" })
local statusCashLabel = StatusCard:AddLabel({ Text = "Cash earned: $0" })
local statusTrainLabel = StatusCard:AddLabel({ Text = "Train: idle (0 reps)" })
local statusMachineLabel = StatusCard:AddLabel({ Text = "Machine: idle (0 reps)" })
local statusBoxingLabel = StatusCard:AddLabel({ Text = "Boxing: idle (0 hits, 0 bought)" })

local STAT_NAMES = { "STR", "ST", "AG", "BS", "DUR", "UM", "LM" }
local STAT_FULL = {
	STR = "Strength",
	ST = "Stamina",
	AG = "Agility",
	BS = "Battle Sense",
	DUR = "Durability",
	UM = "Upper Muscle",
	LM = "Lower Muscle",
}
local statLabels = {}
for _, name in ipairs(STAT_NAMES) do
	statLabels[name] = StatsCard:AddLabel({ Text = ("%s: --"):format(STAT_FULL[name]) })
end

local TOTAL_STAT_NAMES = { "STR", "ST", "AG", "BS", "DUR" }
local statTotalLabel = StatsCard:AddLabel({ Text = "Total Stats: --" })
local statPotentialLabel = StatsCard:AddLabel({ Text = "Potential: --" })

local STAT_RANKS = {
	{ 0, "F-" }, { 26, "F" }, { 51, "F+" }, { 76, "E-" }, { 126, "E" }, { 176, "E+" },
	{ 226, "D-" }, { 326, "D" }, { 426, "D+" }, { 526, "C-" }, { 726, "C" }, { 926, "C+" },
	{ 1126, "B-" }, { 1426, "B" }, { 1726, "B+" }, { 2026, "A-" }, { 2751, "A" }, { 3476, "A+" },
	{ 4201, "S-" }, { 5201, "S" }, { 6201, "S+" }, { 7201, "SS-" }, { 8701, "SS" }, { 10001, "SS+" },
	{ 12501, "SSS-" }, { 15001, "SSS" }, { 17501, "SSS+" }, { 20001, "X-" }, { 24001, "X" }, { 28001, "X+" },
	{ 32001, "XX-" }, { 38001, "XX" }, { 44001, "XX+" }, { 50001, "XXX-" }, { 60001, "XXX" }, { 70001, "XXX+" },
	{ 80001, "Z-" }, { 95001, "Z" }, { 110001, "Z+" }, { 125001, "ZZ-" }, { 145001, "ZZ" }, { 165001, "ZZ+" },
	{ 185001, "ZZZ-" }, { 210001, "ZZZ" }, { 235001, "ZZZ+" }, { 265001, "UR-" }, { 295001, "UR" }, { 325001, "UR+" },
	{ 360001, "LR-" }, { 395001, "LR" }, { 430001, "LR+" }, { 470001, "MR-" }, { 510001, "MR" }, { 550001, "MR+" },
	{ 595001, "EX-" }, { 650001, "EX" }, { 695001, "EX+" }, { 745001, "DX-" }, { 795001, "DX" }, { 845001, "DX+" },
	{ 900001, "?" }, { 1250001, "??" }, { 1750001, "???" },
}

local function statTotal(now)
	local total = 0
	for _, name in ipairs(TOTAL_STAT_NAMES) do
		local v = now[name]
		if type(v) == "number" then total += v end
	end
	return total
end

local function statPotential(total)
	local rank = "F-"
	for _, r in ipairs(STAT_RANKS) do
		if total >= r[1] then rank = r[2] end
	end
	return rank
end

local statsBase = nil

local function readStats()
	local ok, data = pcall(Utility.SnipeData, lp)
	if not ok or typeof(data) ~= "Instance" then return nil end
	local stats = data:FindFirstChild("Statistics")
	if not stats then return nil end
	local out = {}
	for _, c in stats:GetChildren() do
		if c:IsA("IntValue") or c:IsA("NumberValue") then
			out[c.Name] = c.Value
		end
	end
	return out
end

local function refreshStats()
	local now = readStats()
	if not now then
		return
	end
	for _, name in ipairs(STAT_NAMES) do
		local label = statLabels[name]
		if label then
			local v = now[name]
			local base = statsBase and statsBase[name]
			if type(v) == "number" then
				if base and type(base) == "number" and v ~= base then
					local gain = v - base
					local sign = gain > 0 and "+" or ""
					label:SetText(("%s: %s (%s%.4g)"):format(STAT_FULL[name], Utility.roundNumber(v, 2), sign, gain))
				else
					label:SetText(("%s: %s"):format(STAT_FULL[name], Utility.roundNumber(v, 2)))
				end
			end
		end
	end
	local total = statTotal(now)
	local baseTotal = statsBase and statTotal(statsBase)
	if type(baseTotal) == "number" and total ~= baseTotal then
		local gain = total - baseTotal
		statTotalLabel:SetText(("Total Stats: %s (+%s)"):format(Utility.roundNumber(total, 2), Utility.roundNumber(gain, 2)))
	else
		statTotalLabel:SetText(("Total Stats: %s"):format(Utility.roundNumber(total, 2)))
	end
	statPotentialLabel:SetText(("Potential: %s"):format(statPotential(total)))
end

local function refreshStatus()
	if statusJobsLabel then
		statusJobsLabel:SetText(("Jobs completed: %d"):format(bot.jobsDone))
	end
	if statusCashLabel then
		statusCashLabel:SetText(("Cash earned: $%.0f"):format(bot.cashEarned))
	end
	if statusTrainLabel then
		statusTrainLabel:SetText(("Train: %s %s (%d reps)"):format(train.method, train.enabled and "on" or "idle", train.reps))
	end
	if statusMachineLabel then
		statusMachineLabel:SetText(("Machine: %s %s (%d reps)"):format(machine.method, machine.enabled and "on" or "idle", machine.reps))
	end
	if statusBoxingLabel then
		statusBoxingLabel:SetText(("Boxing: %s (%d hits, %d bought)"):format(boxing.enabled and "on" or "idle", boxing.reps, boxing.pairs))
	end
end

refreshStatus()

task.spawn(function()
	while STATE.alive() do
		refreshStatus()
		refreshStats()
		task.wait(2)
	end
end)

local function updateStatus(text)
	Library:Notify({ Title = "Ryujin Jobs", Description = text, Time = 3 })
end

local skipped = {}

task.spawn(function()
	while STATE.alive() do
		if bot.enabled and not bot.working then
			bot.working = true
			local ok, err = pcall(function()
			while bot.enabled do
				waitFlightIdle()
				local aj = jobs.activejob
				if not aj then
					local r = claimJob()
					if r ~= "claimed" then
						updateStatus(r)
						task.wait(3)
					end
					elseif skipped[aj] or not jobEnabled(aj.jobtype) then
						skipped[aj] = true
						cancelActiveJob()
						task.wait(2)
					else
						local cashBefore = getCash()
						local r = executeJob(aj)
						if r:find("cancelled") then
							bot.stuckCount = 0
							updateStatus("mode switch cancelled travel")
							waitFlightIdle()
						elseif r:find("complete") then
							local earned = aj.reward or math.max(0, (getCash() or cashBefore or 0) - (cashBefore or 0))
							bot.jobsDone += 1
							bot.cashEarned += earned
							bot.stuckCount = 0
							refreshStatus()
							Library:Notify({ Title = "Job done", Description = ("%s | +$%d | %d total"):format(r, earned, bot.jobsDone), Time = 4 })
							if autoBank.enabled then
								local dres = depositExcess()
								if dres ~= "disabled" and dres ~= "nothing to store" and dres ~= "no account" and dres ~= "no bank data" then
									updateStatus("Auto bank: " .. dres)
								end
							end
						else
							bot.stuckCount += 1
							if bot.stuckCount >= 2 then
								skipped[aj] = true
								updateStatus(r .. " - skipping this job")
							else
								updateStatus(r)
							end
						end
					-- Only go back to board if job is done/cleared
					if not jobs.activejob then
						goBackToBoard()
						task.wait(2)
					else
						-- Job still active, wait for it to clear before going back
						local t0 = os.clock()
						while bot.enabled and jobs.activejob and os.clock() - t0 < 25 do
							task.wait(1)
						end
						if not jobs.activejob then
							goBackToBoard()
						end
						task.wait(2)
					end
					end
					task.wait(0.5)
				end
			end)
			if not ok then
				warn("[ryujin] job loop error: " .. tostring(err))
			end
			bot.working = false
		end
		task.wait(0.5)
	end
end)

STATE.onCleanup(function()
	flyStop()
	train.enabled = false
	machine.enabled = false
	boxing.enabled = false
	bot.enabled = false
	autoBank.enabled = false
	getgenv().__flyTo = nil
	getgenv().__flyStop = nil
	getgenv().__flyHold = nil
	pcall(function()
		jobs.Cleanup = origCleanup
	end)
	pcall(function()
		Library:Unload()
	end)
end)

return "ryujin-jobs ready"
