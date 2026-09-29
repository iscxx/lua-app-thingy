-- Connected Discord-GitHub

-- Roblox services used by the navigation controller.
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

-- Required objects are resolved once so the controller does not repeatedly search.
local dummy = Workspace:WaitForChild("Dummy")
local mazeExit = Workspace:WaitForChild("MazeExit")

-- Humanoid handles movement and the root part provides the NPC transform.
local humanoid = dummy:WaitForChild("Humanoid")
local rootPart = dummy:WaitForChild("HumanoidRootPart")

-- Centralized settings keep navigation values easy to adjust.
local CONFIG = {
	WalkSpeed = 22,
	AgentRadius = 2,
	AgentHeight = 5,
	AgentCanJump = true,
	AgentCanClimb = false,
	WaypointSpacing = 3,
	RepathDelay = 0.75,
	StuckTime = 2.5,
	ArrivalDistance = 3.5,
	ExitDistance = 6,
	MaxPathAttempts = 12,
	Debug = true,
	DebugLifetime = 1.5,
}

-- States describe the current responsibility of the controller.
local State = {
	Starting = "Starting",
	Searching = "Searching",
	Moving = "Moving",
	Recalculating = "Recalculating",
	Escaped = "Escaped",
	Failed = "Failed",
}

local currentState = State.Starting
local currentPath = nil
local currentWaypoints = {}
local currentWaypointIndex = 0
local pathBlockedConnection = nil
local heartbeatConnection = nil

local lastPathTime = 0
local lastPosition = rootPart.Position
local lastProgressTime = os.clock()
local pathAttempts = 0

local recalculationRequested = false
local finished = false

-- Debug output can be disabled without changing the navigation system.
local function debugPrint(...)
	if CONFIG.Debug then
		print("[MazeAI]", ...)
	end
end

-- Centralized state changes make the AI easier to inspect.
local function setState(newState)
	if currentState == newState then
		return
	end

	currentState = newState
	debugPrint("State:", newState)
end

-- Temporary markers help demonstrate the generated navigation path.
local function createDebugMarker(position, size, lifetime)
	if not CONFIG.Debug then
		return nil
	end

	local marker = Instance.new("Part")
	marker.Name = "MazeAI_DebugMarker"
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanTouch = false
	marker.CanQuery = false
	marker.Material = Enum.Material.Neon
	marker.Transparency = 0.25
	marker.Size = size
	marker.CFrame = CFrame.new(position)
	marker.Parent = Workspace

	Debris:AddItem(marker, lifetime or CONFIG.DebugLifetime)

	return marker
end

-- Waypoints receive small markers so the path is visible during testing.
local function markWaypoint(position, index)
	local marker = createDebugMarker(
		position + Vector3.new(0, 0.2, 0),
		Vector3.new(0.6, 0.6, 0.6),
		CONFIG.DebugLifetime
	)

	if marker then
		marker.Name = "MazeAI_Waypoint_" .. tostring(index)
	end
end

-- Raycast parameters exclude the Dummy so its own body cannot block checks.
local function createRaycastParameters()
	local parameters = RaycastParams.new()

	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = {dummy}
	parameters.IgnoreWater = true

	return parameters
end

-- This checks whether the exit can currently be reached without an obstacle.
local function hasClearLineToExit()
	local origin = rootPart.Position + Vector3.new(0, 2, 0)
	local target = mazeExit.Position + Vector3.new(0, 2, 0)
	local direction = target - origin

	if direction.Magnitude <= 0.05 then
		return true
	end

	local result = Workspace:Raycast(
		origin,
		direction,
		createRaycastParameters()
	)

	if not result then
		return true
	end

	return result.Instance == mazeExit
end

-- Vector3 magnitude provides the distance between the NPC and the exit.
local function getExitDistance()
	return (rootPart.Position - mazeExit.Position).Magnitude
end

-- The controller should never continue navigation after death.
local function isAlive()
	return humanoid.Health > 0
end

-- The exit distance is checked separately from waypoint completion.
local function hasEscaped()
	return getExitDistance() <= CONFIG.ExitDistance
end

-- Horizontal distance prevents small vertical differences from causing
-- the NPC to miss a waypoint on stairs or uneven terrain.
local function hasReachedPosition(position)
	local current = Vector3.new(
		rootPart.Position.X,
		0,
		rootPart.Position.Z
	)

	local target = Vector3.new(
		position.X,
		0,
		position.Z
	)

	return (current - target).Magnitude <= CONFIG.ArrivalDistance
end

-- Old Blocked events must be disconnected before replacing a path.
local function disconnectPathConnection()
	if pathBlockedConnection then
		pathBlockedConnection:Disconnect()
		pathBlockedConnection = nil
	end
end

-- Clearing these values gives every new route a clean navigation state.
local function clearPath()
	disconnectPathConnection()

	currentPath = nil
	currentWaypoints = {}
	currentWaypointIndex = 0
end

-- The Humanoid is configured once because its movement properties are shared
-- by every waypoint rather than needing to be reassigned for each step.
local function configureHumanoid()
	humanoid.WalkSpeed = CONFIG.WalkSpeed
	humanoid.AutoRotate = true
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 45
end

-- Server ownership makes the server authoritative over this NPC's physics.
local function configureNetworkOwnership()
	local success, result = pcall(function()
		rootPart:SetNetworkOwner(nil)
		return true
	end)

	if not success then
		debugPrint("Network ownership warning:", result)
	end
end

-- The CFrame lookAt calculation keeps the Dummy facing its current waypoint.
local function faceWaypoint(position)
	local currentPosition = rootPart.Position

	local flatTarget = Vector3.new(
		position.X,
		currentPosition.Y,
		position.Z
	)

	local direction = flatTarget - currentPosition

	if direction.Magnitude <= 0.05 then
		return
	end

	local targetCFrame = CFrame.lookAt(
		currentPosition,
		flatTarget
	)

	rootPart.CFrame = rootPart.CFrame:Lerp(
		targetCFrame,
		0.2
	)
end

-- Jump waypoints contain an explicit PathWaypointAction that the Humanoid
-- needs to receive before continuing along the calculated route.
local function prepareWaypoint(waypoint)
	if waypoint.Action == Enum.PathWaypointAction.Jump then
		humanoid.Jump = true
	end
end

-- MoveTo delegates collision-aware movement to the Roblox Humanoid system.
local function moveToWaypoint(waypoint)
	if not isAlive() then
		return false
	end

	prepareWaypoint(waypoint)
	faceWaypoint(waypoint.Position)
	humanoid:MoveTo(waypoint.Position)

	return true
end

-- Movement progress is measured over time to detect an NPC trapped by geometry.
local function isStuck()
	local movementDistance = (
		rootPart.Position - lastPosition
	).Magnitude

	if movementDistance > 0.35 then
		lastPosition = rootPart.Position
		lastProgressTime = os.clock()

		return false
	end

	return os.clock() - lastProgressTime >= CONFIG.StuckTime
end

-- A blocked path requests a fresh route instead of attempting to force
-- the Humanoid through an obstacle.
local function requestRecalculation(reason)
	if finished then
		return
	end

	recalculationRequested = true

	if reason then
		debugPrint("Recalculation:", reason)
	end

	setState(State.Recalculating)
end

-- Pathfinding is performed from the NPC's current position to the live exit.
local function computePath()
	if not isAlive() then
		return false
	end

	if not mazeExit:IsDescendantOf(Workspace) then
		debugPrint("MazeExit is missing from Workspace.")
		return false
	end

	local path = PathfindingService:CreatePath({
		AgentRadius = CONFIG.AgentRadius,
		AgentHeight = CONFIG.AgentHeight,
		AgentCanJump = CONFIG.AgentCanJump,
		AgentCanClimb = CONFIG.AgentCanClimb,
		WaypointSpacing = CONFIG.WaypointSpacing,
	})

	local success, errorMessage = pcall(function()
		path:ComputeAsync(
			rootPart.Position,
			mazeExit.Position
		)
	end)

	if not success then
		debugPrint("Path computation error:", errorMessage)
		return false
	end

	if path.Status ~= Enum.PathStatus.Success then
		debugPrint("Path status:", path.Status.Name)
		return false
	end

	local waypoints = path:GetWaypoints()

	if #waypoints < 2 then
		debugPrint("Path returned too few waypoints.")
		return false
	end

	disconnectPathConnection()

	currentPath = path
	currentWaypoints = waypoints
	currentWaypointIndex = 2
	lastPathTime = os.clock()
	lastProgressTime = os.clock()
	lastPosition = rootPart.Position
	pathAttempts += 1

	-- Blocked fires when Roblox detects that a later waypoint is no longer usable.
	pathBlockedConnection = path.Blocked:Connect(function(blockedIndex)
		if blockedIndex >= currentWaypointIndex then
			requestRecalculation("Path blocked")
		end
	end)

	-- Debug markers allow the reviewer to see the route calculated by Roblox.
	if CONFIG.Debug then
		for index, waypoint in ipairs(waypoints) do
			markWaypoint(waypoint.Position, index)
		end
	end

	debugPrint("Path created:", #waypoints, "waypoints")

	return true
end

-- This function handles the normal waypoint-by-waypoint navigation loop.
local function followPath()
	if #currentWaypoints == 0 then
		return false
	end

	if currentWaypointIndex > #currentWaypoints then
		return false
	end

	local waypoint = currentWaypoints[currentWaypointIndex]

	if hasReachedPosition(waypoint.Position) then
		currentWaypointIndex += 1
		lastPosition = rootPart.Position
		lastProgressTime = os.clock()

		return true
	end

	moveToWaypoint(waypoint)

	return true
end

-- Reaching the final path waypoint is not enough; the NPC must actually
-- enter the configured exit radius.
local function validatePathCompletion()
	if currentWaypointIndex <= #currentWaypoints then
		return false
	end

	if hasEscaped() then
		return true
	end

	requestRecalculation("Final waypoint reached without exit")

	return false
end

-- The completion effect makes successful escape obvious in a demonstration.
local function createEscapeEffect()
	local highlight = Instance.new("Highlight")

	highlight.Name = "MazeAI_EscapeEffect"
	highlight.Adornee = dummy
	highlight.FillTransparency = 0.25
	highlight.OutlineTransparency = 0
	highlight.Parent = dummy

	local tween = TweenService:Create(
		highlight,
		TweenInfo.new(
			1,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		),
		{
			FillTransparency = 1,
			OutlineTransparency = 1,
		}
	)

	tween:Play()

	Debris:AddItem(highlight, 1.2)
end

-- Successful escape stops every navigation operation and freezes the NPC.
local function finishEscape()
	if finished then
		return
	end

	finished = true

	setState(State.Escaped)
	clearPath()

	humanoid:Move(Vector3.zero)
	humanoid.WalkSpeed = 0

	createEscapeEffect()

	debugPrint("Dummy escaped the maze.")
end

-- A controlled failure makes impossible maze configurations easy to identify.
local function finishFailure(reason)
	if finished then
		return
	end

	finished = true

	setState(State.Failed)
	clearPath()

	humanoid:Move(Vector3.zero)

	debugPrint("Navigation failed:", reason)
end

-- This function creates the first route before normal movement begins.
local function initializeNavigation()
	setState(State.Searching)

	local success = computePath()

	if success then
		setState(State.Moving)
		return true
	end

	return false
end

-- Path attempts are limited so a broken maze cannot create an infinite
-- server-side pathfinding loop.
local function canAttemptPath()
	return pathAttempts < CONFIG.MaxPathAttempts
end

-- Recalculation is delayed slightly to avoid repeatedly computing paths
-- when several physics events happen during the same moment.
local function handleRecalculation()
	if not recalculationRequested then
		return
	end

	if os.clock() - lastPathTime < CONFIG.RepathDelay then
		return
	end

	if not canAttemptPath() then
		finishFailure("Maximum path attempts reached")
		return
	end

	recalculationRequested = false

	clearPath()

	setState(State.Recalculating)

	local success = computePath()

	if success then
		setState(State.Moving)
	else
		recalculationRequested = true
	end
end

-- The main update combines state handling without creating multiple loops.
local function update()
	if finished then
		return
	end

	if not isAlive() then
		finishFailure("Dummy died")
		return
	end

	if hasEscaped() then
		finishEscape()
		return
	end

	handleRecalculation()

	if finished then
		return
	end

	if currentPath == nil then
		if not canAttemptPath() then
			finishFailure("Unable to create a valid path")
			return
		end

		if os.clock() - lastPathTime < CONFIG.RepathDelay then
			return
		end

		setState(State.Searching)

		local success = computePath()

		if success then
			setState(State.Moving)
		else
			lastPathTime = os.clock()
		end

		return
	end

	if currentState ~= State.Moving then
		return
	end

	if isStuck() then
		requestRecalculation("Dummy stopped moving")
		return
	end

	if validatePathCompletion() then
		finishEscape()
		return
	end

	followPath()
end

-- Heartbeat provides a single centralized update loop for the entire AI.
local function startController()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
	end

	heartbeatConnection = RunService.Heartbeat:Connect(update)
end

-- Cleanup prevents old connections from surviving after the NPC is removed.
local function cleanup()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end

	disconnectPathConnection()
	clearPath()
end

-- Death immediately stops the navigation controller.
humanoid.Died:Connect(function()
	debugPrint("Dummy died.")
	cleanup()
end)

-- Removing the NPC from Workspace also terminates the controller.
dummy.AncestryChanged:Connect(function(_, parent)
	if parent == nil then
		cleanup()
	end
end)

-- Moving the exit during Studio testing invalidates the current route.
mazeExit:GetPropertyChangedSignal("Position"):Connect(function()
	if not finished then
		requestRecalculation("Exit moved")
	end
end)

-- Configure physics before the first path is requested.
configureHumanoid()
configureNetworkOwnership()

-- The short delay allows maze collision geometry to finish loading.
task.wait(0.5)

-- Build the initial route and begin the single update loop.
if initializeNavigation() then
	startController()
else
	finishFailure("Initial path could not be created")
end