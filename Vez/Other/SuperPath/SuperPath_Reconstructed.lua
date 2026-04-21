--!optimize 2
-- SuperPath — single-file build for loadstring / LocalScript use.
-- Contains: Config, Signal (SignalPlus v3.7.2 MIT © Alexander Lindholt), PathUtils, SuperPath.

local PFS    = game:GetService("PathfindingService")
local CS     = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

-- Types (plain `type`, NOT `export type`, so loadstring works)
type ErrorType =
	"CompError" | "RateLimit" | "AgentStuck" | "TargetUnreachable" | "MaxDistExceeded"

--========================= CONFIG =========================--
local Config = {
	RATE_LIMIT = 0.1,
	DO_STUCK_CHECKS = true,
	STUCK_CHECKS = 1,
	RETRY_ON_BLOCKED = false,
	DELETE_UNNEEDED_WAYPOINTS = true,
	MINIMUM_SPACING = 1,
	ON_FALL_NO_JUMP = false,
	ON_STEPUP_NO_JUMP = false,
	RAYCAST_PRE_RUN = false,
	RAYCAST_SETTINGS = {
		FilterType = Enum.RaycastFilterType.Exclude,
		FilteredTags = {},
		FilteredInstances = {},
		Cooldown = 0,
		MaxYOffset = 2,
	},
	WAYPOINT_TIMEOUT = 8,
	VISUALIZE = false,
	VISUALIZER_COLOURS = {
		REGULAR = Color3.new(1, 0.36, 0),
		GOAL    = Color3.new(0.28, 1, 0.02),
		JUMP    = Color3.new(0.48, 0.42, 1),
		SPECIAL = Color3.new(0, 0.01, 1),
	},
	VISUALIZER_PARENT = workspace,
}

--========================= SIGNAL =========================--
local Signal
do
	local spawnThread = task.spawn
	local threads = {}
	local function reusableThreadCall(callback, thread, ...)
		local items = {...}
		pcall(function()
			callback(unpack(items))
			table.insert(threads, thread)
		end)
	end
	local function reusableThread()
		while true do reusableThreadCall(coroutine.yield()) end
	end
	local function disconnect(c)
		if not c.Connected then return end
		c.Connected = nil
		local s, p, n = c.Signal, c.Previous, c.Next
		if p then p.Next = n else s.Tail = n end
		if n then n.Previous = p else s.Head = p end
	end
	local S = {}; S.__index = S
	S.Connect = function(signal, cb)
		local head = signal.Head
		local c = { Signal=signal, Previous=head, Callback=cb, Connected=true, Disconnect=disconnect }
		if head then head.Next = c else signal.Tail = c end
		signal.Head = c
		return c
	end
	S.Once = function(signal, cb)
		local head = signal.Head
		local c
		c = {
			Signal=signal, Previous=head, Connected=true, Disconnect=disconnect,
			Callback=function(...)
				if not c.Connected then return end
				c.Connected = false
				local p, n = c.Previous, c.Next
				if p then p.Next=n else signal.Tail=n end
				if n then n.Previous=p else signal.Head=p end
				cb(...)
			end
		}
		if head then head.Next = c else signal.Tail = c end
		signal.Head = c
		return c
	end
	S.Wait = function(signal)
		local thread = coroutine.running()
		local head = signal.Head
		local c
		c = {
			Previous=head,
			Callback=function(...)
				c.Connected = false
				local p, n = c.Previous, c.Next
				if p then p.Next=n else signal.Tail=n end
				if n then n.Previous=p else signal.Head=p end
				if coroutine.status(thread) == "suspended" then task.spawn(thread, ...) end
			end
		}
		if head then head.Next = c else signal.Tail = c end
		signal.Head = c
		return coroutine.yield()
	end
	S.Fire = function(signal, ...)
		local c = signal.Tail
		while c do
			local len = #threads
			if len == 0 then
				local th = coroutine.create(reusableThread)
				coroutine.resume(th)
				spawnThread(th, c.Callback, th, ...)
			else
				local th = threads[len]; threads[len] = nil
				spawnThread(th, c.Callback, th, ...)
			end
			c = c.Next
		end
	end
	S.DisconnectAll = function(signal)
		local c = signal.Tail
		while c do local nx=c.Next; c.Connected=nil; c.Next=nil; c.Previous=nil; c=nx end
		signal.Tail, signal.Head = nil, nil
	end
	S.Destroy = function(signal)
		local c = signal.Tail
		while c do local nx=c.Next; c.Connected=nil; c.Next=nil; c.Previous=nil; c=nx end
		signal.Tail, signal.Head = nil, nil
		setmetatable(signal, nil)
	end
	Signal = function() return setmetatable({}, S) end
end

--========================= UTIL =========================--
local Util = {}
do
	local VC = Config.VISUALIZER_COLOURS
	local function isSpecialWaypoint(wp)
		if not wp then return false end
		return (not Enum.Material:FromName(wp.Label)) or wp.Action == Enum.PathWaypointAction.Jump
	end
	local function hasUniqueLabel(wp)
		return not Enum.Material:FromName(wp.Label) and wp.Label ~= "Jump"
	end
	local function doWarn(m) warn("[SuperPath]: "..m) end
	local function declareError(self, et) self.LastError = et; self.Error:Fire(et) end

	function Util.Compute(pathObj, origin, goal)
		local path = pathObj.Path
		local DUW, OSNJ, OFNJ = pathObj.DeleteUnneededWaypoints, pathObj.OnStepupNoJump, pathObj.OnFallNoJump
		local ok, err = pcall(function() path:ComputeAsync(origin, goal) end)
		if not ok then doWarn("Failed to compute route: "..err) return false, {}, false end
		if path.Status == Enum.PathStatus.NoPath then return false, {}, false end
		local wps = path:GetWaypoints()
		local kept = nil
		if DUW or OFNJ or OSNJ then
			kept = {}
			for i = 1, #wps do
				local thisWp, lastWp, nextWp = wps[i], wps[i-1], wps[i+1]
				if not thisWp then continue end
				if DUW then
					local a, b = isSpecialWaypoint(thisWp), isSpecialWaypoint(nextWp)
					if not (a or b) and lastWp and (thisWp.Position - lastWp.Position).Magnitude < pathObj.MinimumSpacing then
						continue
					end
				end
				table.insert(kept, thisWp)
				if thisWp.Action.Name == "Jump" then
					local yd = thisWp.Position.Y - lastWp.Position.Y
					if (OFNJ and yd < 0) or (OSNJ and yd < 1) then
						kept[i] = PathWaypoint.new(thisWp.Position, Enum.PathWaypointAction.Walk)
					end
				end
			end
		end
		return true, kept or wps, path.Status.Name == "ClosestNoPath"
	end

	function Util.Visualize(pathObj)
		if not pathObj.Visualize then return end
		pathObj._wpParts = pathObj._wpParts or {}
		for wp in pathObj._wpParts do wp:Destroy() end
		local wps = pathObj.PathWaypoints
		for i, wp in wps do
			local part = Instance.new("Part")
			part.Size = Vector3.new(1,1,1); part.Anchored = true; part.CanCollide = false
			part.Material = Enum.Material.Neon; part.Position = wp.Position
			part.Shape = Enum.PartType.Ball; part.Transparency = 0.35
			if i == #wps then part.Color = VC.GOAL
			elseif wp.Label and hasUniqueLabel(wp) then part.Color = VC.SPECIAL
			elseif wp.Action ~= Enum.PathWaypointAction.Walk then part.Color = VC.JUMP
			else part.Color = VC.REGULAR end
			part.Parent = pathObj.VisualizerParent
			pathObj._wpParts[part] = true
			Debris:AddItem(part, 10)
		end
	end

	function Util.ComparePosition(pathObj)
		local n = pathObj.StuckChecks
		local ps = pathObj.PositionRecords
		table.insert(ps, pathObj.Agent:GetPivot().Position)
		if #ps >= 1 + n then
			if ps[1]:FuzzyEq(ps[#ps], 0.1) then declareError(pathObj, "AgentStuck") end
			table.remove(ps, 1)
		end
	end

	function Util.GetDistance(pathObj, a, b)
		local wps, d = pathObj.PathWaypoints, 0
		for i = a, b do
			local t, l = wps[i], wps[i-1]
			if l then d += (l.Position - t.Position).Magnitude end
		end
		return d
	end

	function Util.RaycastCheck(pathObj, origin, goal)
		local rs = pathObj.RaycastSettings
		if goal.Y - origin.Y > rs.MaxYOffset then return false end
		local tags = rs.FilteredTags
		tags = typeof(tags) == "string" and {tags} or tags
		local p = RaycastParams.new()
		p.FilterType = rs.FilterType
		p:AddToFilter(rs.FilteredInstances)
		for _, tag in tags do p:AddToFilter(CS:GetTagged(tag)) end
		local r = workspace:Raycast(origin, (goal - origin) * 1.005, p)
		if r and r.Instance then return r.Position:FuzzyEq(goal, 0.2) end
		return true
	end
end

--========================= SUPERPATH =========================--
local function clearRoute(p)
	p.WaypointIndex, p.LastWaypoint, p.LatestWaypoint, p.NextWaypoint = 0, nil, nil, nil
	p.CurrentlyPartial, p.PathWaypoints, p.Goal, p.Idle = false, {}, nil, true
end
local function reconcile(default, fallback)
	if typeof(default) == "table" then
		for k, v in pairs(fallback) do if default[k] == nil then default[k] = v end end
		return default
	end
	return if default ~= nil then default else fallback
end
local function toVector3(item)
	local t = typeof(item)
	local isInst = t == "Instance"
	if t == "Vector3" or t == "vector" then return item
	elseif t == "CFrame" or (isInst and item:IsA("BasePart")) then return item.Position
	elseif isInst and item:IsA("Model") then return item:GetPivot().Position end
	return item
end
local function doWarn(m) warn("[SuperPath]: "..m) end
local function declareError(self, et) self.LastError = et; self.Error:Fire(et) end
local function safeCleanUp(self, name)
	local it = self[name]
	if typeof(it) == "thread" then task.cancel(it); self[name] = nil
	elseif typeof(it) == "RBXScriptConnection" then it:Disconnect(); self[name] = nil end
end
local function getAgentPos(self) return self.Agent:GetPivot().Position end
local function freezeAgent(agent)
	local h = agent:FindFirstChild("Humanoid")
	if h then h:MoveTo(agent:GetPivot().Position) end
end

local Path = {}; Path.__index = Path

function Path:Run(goal, origin)
	if not self or self.IsDestroying then return end
	if os.clock() - self.LastRun < self.RateLimit then declareError(self, "RateLimit") return end
	self.RateLimit = os.clock()
	local customOrigin = true
	origin = reconcile(toVector3(origin), (function() customOrigin = false; return getAgentPos(self) end)())
	goal = toVector3(goal)
	clearRoute(self)
	safeCleanUp(self, "_blockCon")
	if self.DoStuckChecks then task.spawn(Util.ComparePosition, self) end
	if self.Humanoid and self.RaycastPreRun then
		if os.clock() - (self._lastRc or 0) >= self.RaycastSettings.Cooldown then
			self._lastRc = os.clock()
			if Util.RaycastCheck(self, self.Agent:GetPivot().Position, goal) then
				self.Idle = false; self.IsPathfinding = false; self.Goal = goal
				self.StartRun:Fire(goal); self.DirectRun:Fire(goal)
				self.Humanoid:MoveTo(goal); return true
			end
		end
	end
	if (goal - origin).Magnitude > 3000 then declareError(self, "MaxDistExceeded") return false end
	local ok, wps, partial = Util.Compute(self, origin, goal)
	if not ok then declareError(self, "CompError") return false end
	self.IsPathfinding, self.IsPartial, self.PathWaypoints = true, partial, wps
	self.NextWaypoint, self.Goal = wps[1], goal
	self.StartRun:Fire(goal)
	Util.Visualize(self)
	self._blockCon = self.Path.Blocked:Connect(function(wpIndex)
		if wpIndex >= self.WaypointIndex then
			safeCleanUp(self, "_blockCon")
			self.Blocked:Fire(self.PathWaypoints[wpIndex], wpIndex)
			if self.RetryOnBlocked then self:Run(goal, origin) end
		end
	end)
	task.spawn(function() self:TravelToWaypoint(1, true, not customOrigin) end)
	return true
end

function Path:TravelToWaypoint(index, shouldContinue, _sF)
	if not self or self.IsDestroying then return end
	safeCleanUp(self, "_observer"); safeCleanUp(self, "_moveCon")
	local wp = self.PathWaypoints[index]
	if not wp then return end
	self.WaypointIndex = index
	self.LastWaypoint, self.LatestWaypoint, self.NextWaypoint =
		self.PathWaypoints[index-2], self.PathWaypoints[index-1], wp
	self.Idle = false
	local function done(reached)
		if self.Idle then return end
		if reached then
			self.WaypointReached:Fire(wp, index)
			if not self.PathWaypoints[index+1] then
				clearRoute(self); self.GoalReached:Fire(wp)
			elseif not self.Idle and shouldContinue then
				self:TravelToWaypoint(index+1, true)
			end
		else
			freezeAgent(self.Agent); declareError(self, "TargetUnreachable")
		end
	end
	self._observer = task.delay(self.WaypointTimeout, function() safeCleanUp(self, "_moveCon"); done(false) end)
	local hum = self.Humanoid
	if hum then
		hum:MoveTo(wp.Position)
		if not (_sF and index == 1) then
			if wp.Action == Enum.PathWaypointAction.Jump and not self.AgentInAir then
				hum.Jump = true
			end
		else done(true) end
		self._moveCon = hum.MoveToFinished:Once(function(reached)
			safeCleanUp(self, "_observer"); safeCleanUp(self, "_moveCon"); done(reached)
		end)
	else
		local a = self.Agent
		self._moveCon = a:GetPropertyChangedSignal("WorldPivot"):Connect(function()
			if a:GetPivot().Position:FuzzyEq(wp.Position) then
				safeCleanUp(self, "_observer"); safeCleanUp(self, "_moveCon"); done(true)
			end
		end)
	end
end

function Path:Pause()
	if not self or self.IsDestroying or self.Idle then return end
	self.Idle = true; freezeAgent(self.Agent); self.Paused:Fire()
end
function Path:Resume()
	if not self or self.IsDestroying or not self.Idle then return end
	self.Idle = false; self.Resumed:Fire()
	if self.IsPathfinding then self:TravelToWaypoint(self.WaypointIndex, true)
	else self.Humanoid:MoveTo(self.Goal) end
end
function Path:Halt()
	if not self or self.IsDestroying or self.Idle then return end
	self.Idle = true; freezeAgent(self.Agent); clearRoute(self); self.Halted:Fire()
end
function Path:GetDistanceSum(a, b)
	if not self or self.IsDestroying then return end
	if self.Idle then return 0 end
	return Util.GetDistance(self, a or self.WaypointIndex, b or #self.PathWaypoints)
end
function Path:ChangeAgentParams(p)
	if not self or self.IsDestroying then return end
	local s, err = pcall(function() self.Path = PFS:CreatePath(p) end)
	if not s then doWarn("Failed to create path: "..err); return false end
	self.AgentParamsChanged:Fire(p); return true
end
function Path:Destroy()
	if not self or self.IsDestroying then return end
	freezeAgent(self.Agent); self.Destroying:Fire(); self.IsDestroying = true
	task.spawn(function()
		task.wait(); setmetatable(self, nil)
		for i, v in self do
			pcall(function() v:Disconnect(); v:Destroy() end)
			self[i] = nil
		end
	end)
end

local SuperPath = {
	ErrorType = {
		TargetUnreachable = "TargetUnreachable",
		AgentStuck = "AgentStuck",
		CompError = "CompError",
		MaxDistExceeded = "MaxDistExceeded",
	}
}
function SuperPath.Agent(agent, agentParams, pathSettings)
	pathSettings = pathSettings or {}
	local useHum = reconcile(pathSettings.UseHumanoid, true)
	local path
	local s, err = pcall(function() path = PFS:CreatePath(agentParams) end)
	if not s then doWarn("Failed to create path: "..err) end

	local self = setmetatable({
		WaypointTimeout         = reconcile(pathSettings.WaypointTimeout, Config.WAYPOINT_TIMEOUT),
		Visualize               = reconcile(pathSettings.Visualize, Config.VISUALIZE),
		VisualizerParent        = reconcile(pathSettings.VisualizerParent, Config.VISUALIZER_PARENT),
		DeleteUnneededWaypoints = reconcile(pathSettings.DeleteUnneededWaypoints, Config.DELETE_UNNEEDED_WAYPOINTS),
		MinimumSpacing          = reconcile(pathSettings.MinimumSpacing, Config.MINIMUM_SPACING),
		OnFallNoJump            = reconcile(pathSettings.OnFallNoJump, Config.ON_FALL_NO_JUMP),
		OnStepupNoJump          = reconcile(pathSettings.OnStepupNoJump, Config.ON_STEPUP_NO_JUMP),
		DoStuckChecks           = reconcile(pathSettings.DoStuckChecks, Config.DO_STUCK_CHECKS),
		StuckChecks             = reconcile(pathSettings.StuckChecks, Config.STUCK_CHECKS),
		RetryOnBlocked          = reconcile(pathSettings.RetryOnBlocked, Config.RETRY_ON_BLOCKED),
		RaycastPreRun           = reconcile(pathSettings.RaycastPreRun, Config.RAYCAST_PRE_RUN),
		RaycastSettings         = reconcile(pathSettings.RaycastSettings, Config.RAYCAST_SETTINGS),
		RateLimit               = reconcile(pathSettings.RateLimit, Config.RATE_LIMIT),

		Agent = agent,
		Humanoid = (useHum and agent:FindFirstChild("Humanoid")) or nil,
		Path = path, Idle = true, LastError = nil, WaypointIndex = 0,
		LastWaypoint = nil, LatestWaypoint = nil, NextWaypoint = nil,
		IsPartial = false, PathWaypoints = {}, Goal = nil,
		PositionRecords = {}, AgentInAir = false, IsPathfinding = true,
		IsDestroying = false, LastRun = 0,

		Error = Signal(), Blocked = Signal(), Paused = Signal(), Resumed = Signal(),
		Halted = Signal(), AgentParamsChanged = Signal(), WaypointReached = Signal(),
		GoalReached = Signal(), StartRun = Signal(), DirectRun = Signal(),
		OnJump = Signal(), Destroying = Signal(),
	}, Path)

	local hum = self.Humanoid
	if hum then
		self._airCon = hum:GetPropertyChangedSignal("FloorMaterial"):Connect(function()
			self.AgentInAir = hum.FloorMaterial.Name == "Air"
		end)
	end
	return self
end

return SuperPath
