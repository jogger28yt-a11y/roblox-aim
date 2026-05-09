-- Auto lock caméra + déplacement safe allégé
-- Garde 39 studs avec la cible, évite le vide, réduit les freeze

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

--// Réglages cible

local AimPart = "HumanoidRootPart"
local MaxTargetDistance = 300

local DesiredDistance = 39
local DistanceTolerance = 2

--// Pathfinding allégé

local RecalculatePathDelay = 0.7
local WaypointReachDistance = 5
local JumpHeightDifference = 1.5

--// Anti-vide allégé

local GroundCheckDepth = 50
local GroundCheckHeight = 8
local MaxSafeDrop = 18
local SegmentCheckStep = 7
local FootCheckRadius = 1.1

--// Moins de positions testées = moins de freeze

local AroundTargetSamples = 12

--// Anti-blocage

local StuckCheckDelay = 1
local StuckDistance = 1.5
local StuckLimit = 2

--// Mur / obstacle

local WallCheckDistance = 4
local WallJumpCooldown = 0.35

local LockEnabled = true

local currentPath = nil
local waypoints = {}
local currentWaypointIndex = 1
local lastPathCalculation = 0
local currentDestination = nil

local lastPosition = nil
local lastStuckCheck = 0
local stuckCount = 0
local lastWallJump = 0

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude

local wallRayParams = RaycastParams.new()
wallRayParams.FilterType = Enum.RaycastFilterType.Exclude

local function getCharacter(player)
	local character = player.Character
	if not character then return nil end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")

	if not humanoid or not root then
		return nil
	end

	if humanoid.Health <= 0 then
		return nil
	end

	return character, humanoid, root
end

local function hardStop(humanoid)
	humanoid:Move(Vector3.zero, false)
end

local function clearPath()
	currentPath = nil
	waypoints = {}
	currentWaypointIndex = 1
	currentDestination = nil
end

local function getClosestPlayer()
	local _, _, myRoot = getCharacter(LocalPlayer)
	if not myRoot then return nil end

	local closestPlayer = nil
	local closestDistance = MaxTargetDistance

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= LocalPlayer then
			local character, humanoid, root = getCharacter(otherPlayer)

			if character and humanoid and root then
				local distance = (root.Position - myRoot.Position).Magnitude

				if distance < closestDistance then
					closestDistance = distance
					closestPlayer = otherPlayer
				end
			end
		end
	end

	return closestPlayer
end

local function raycastGround(position, character)
	raycastParams.FilterDescendantsInstances = { character }

	local rayOrigin = position + Vector3.new(0, GroundCheckHeight, 0)
	local rayDirection = Vector3.new(0, -GroundCheckDepth, 0)

	return Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
end

local function hasSafeGroundAt(position, character, referenceY)
	local result = raycastGround(position, character)

	if not result then
		return false, nil
	end

	local groundPosition = result.Position

	if referenceY then
		local drop = referenceY - groundPosition.Y

		if drop > MaxSafeDrop then
			return false, nil
		end
	end

	return true, groundPosition
end

local function isFootprintSafe(position, character, referenceY)
	local checks = {
		Vector3.new(0, 0, 0),
		Vector3.new(FootCheckRadius, 0, 0),
		Vector3.new(-FootCheckRadius, 0, 0),
		Vector3.new(0, 0, FootCheckRadius),
		Vector3.new(0, 0, -FootCheckRadius),
	}

	for _, offset in ipairs(checks) do
		local safe = hasSafeGroundAt(position + offset, character, referenceY)

		if not safe then
			return false
		end
	end

	return true
end

local function isSegmentSafe(startPosition, endPosition, character)
	local direction = endPosition - startPosition
	local distance = direction.Magnitude

	if distance <= 0 then
		return true
	end

	local steps = math.ceil(distance / SegmentCheckStep)
	local referenceY = startPosition.Y

	for i = 0, steps do
		local alpha = i / steps
		local checkPosition = startPosition:Lerp(endPosition, alpha)

		if not isFootprintSafe(checkPosition, character, referenceY) then
			return false
		end
	end

	return true
end

local function checkWallAhead(root, character, direction)
	if direction.Magnitude <= 0 then
		return false
	end

	wallRayParams.FilterDescendantsInstances = { character }

	local flatDirection = Vector3.new(direction.X, 0, direction.Z)

	if flatDirection.Magnitude <= 0 then
		return false
	end

	local rayOrigin = root.Position + Vector3.new(0, 2, 0)
	local rayDirection = flatDirection.Unit * WallCheckDistance

	local result = Workspace:Raycast(rayOrigin, rayDirection, wallRayParams)

	if result and result.Instance and result.Instance.CanCollide then
		return true
	end

	return false
end

local function tryClimbObstacle(humanoid, root, character, direction)
	local now = os.clock()

	if now - lastWallJump < WallJumpCooldown then
		return
	end

	if checkWallAhead(root, character, direction) then
		lastWallJump = now
		humanoid.Jump = true
		humanoid:Move(direction.Unit, false)
	end
end

local function computePathTo(destination)
	local myCharacter, _, myRoot = getCharacter(LocalPlayer)

	if not myCharacter or not myRoot then
		return nil, nil
	end

	local hasGround, groundPosition = hasSafeGroundAt(destination, myCharacter, myRoot.Position.Y)

	if not hasGround then
		return nil, nil
	end

	local finalDestination = Vector3.new(
		destination.X,
		groundPosition.Y + 2,
		destination.Z
	)

	if not isFootprintSafe(finalDestination, myCharacter, myRoot.Position.Y) then
		return nil, nil
	end

	local path = PathfindingService:CreatePath({
		AgentRadius = 1.5,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentCanClimb = true,
		AgentJumpHeight = 12,
		AgentMaxSlope = 50,
		WaypointSpacing = 4
	})

	local success = pcall(function()
		path:ComputeAsync(myRoot.Position, finalDestination)
	end)

	if success and path.Status == Enum.PathStatus.Success then
		return path, finalDestination
	end

	return nil, nil
end

local function pathIsSafe(path, character, root)
	local pathWaypoints = path:GetWaypoints()

	if #pathWaypoints == 0 then
		return false
	end

	local previousPosition = root.Position

	for _, waypoint in ipairs(pathWaypoints) do
		local waypointPosition = waypoint.Position

		if not isFootprintSafe(waypointPosition, character, root.Position.Y) then
			return false
		end

		if not isSegmentSafe(previousPosition, waypointPosition, character) then
			return false
		end

		previousPosition = waypointPosition
	end

	return true
end

local function findBestSafePositionAroundTarget(myRoot, targetRoot)
	local myCharacter = LocalPlayer.Character

	if not myCharacter then
		return nil, nil
	end

	local targetPosition = targetRoot.Position

	local bestPath = nil
	local bestDestination = nil
	local bestScore = math.huge

	for i = 1, AroundTargetSamples do
		local angle = math.pi * 2 * (i / AroundTargetSamples)

		local offset = Vector3.new(
			math.cos(angle) * DesiredDistance,
			0,
			math.sin(angle) * DesiredDistance
		)

		local candidate = targetPosition + offset
		local path, finalDestination = computePathTo(candidate)

		if path and finalDestination and pathIsSafe(path, myCharacter, myRoot) then
			local distanceFromMe = (finalDestination - myRoot.Position).Magnitude
			local distanceFromTarget = (finalDestination - targetRoot.Position).Magnitude
			local distanceError = math.abs(distanceFromTarget - DesiredDistance)

			local score = distanceFromMe + distanceError * 3

			if score < bestScore then
				bestScore = score
				bestPath = path
				bestDestination = finalDestination
			end
		end
	end

	return bestPath, bestDestination
end

local function forceJumpIfNeeded(humanoid, root, waypoint, character)
	if not waypoint then return end

	local heightDifference = waypoint.Position.Y - root.Position.Y

	if not isFootprintSafe(waypoint.Position, character, root.Position.Y) then
		return
	end

	if waypoint.Action == Enum.PathWaypointAction.Jump then
		humanoid.Jump = true
	end

	if heightDifference >= JumpHeightDifference then
		humanoid.Jump = true
	end
end

local function checkIfStuck(root)
	local now = os.clock()

	if not lastPosition then
		lastPosition = root.Position
		lastStuckCheck = now
		return false
	end

	if now - lastStuckCheck < StuckCheckDelay then
		return false
	end

	local movedDistance = (root.Position - lastPosition).Magnitude

	lastPosition = root.Position
	lastStuckCheck = now

	if movedDistance < StuckDistance then
		stuckCount += 1
	else
		stuckCount = 0
	end

	if stuckCount >= StuckLimit then
		stuckCount = 0
		return true
	end

	return false
end

local function followPath(humanoid, root, character)
	if not waypoints or #waypoints == 0 then
		hardStop(humanoid)
		return
	end

	local waypoint = waypoints[currentWaypointIndex]

	if not waypoint then
		hardStop(humanoid)
		return
	end

	local distanceToWaypoint = (waypoint.Position - root.Position).Magnitude

	if distanceToWaypoint <= WaypointReachDistance then
		currentWaypointIndex += 1
		waypoint = waypoints[currentWaypointIndex]

		if not waypoint then
			hardStop(humanoid)
			return
		end
	end

	local nextPosition = waypoint.Position
	local direction = nextPosition - root.Position
	local flatDirection = Vector3.new(direction.X, 0, direction.Z)

	if not isFootprintSafe(root.Position, character, root.Position.Y) then
		hardStop(humanoid)
		clearPath()
		return
	end

	if not isFootprintSafe(nextPosition, character, root.Position.Y) then
		hardStop(humanoid)
		clearPath()
		return
	end

	if not isSegmentSafe(root.Position, nextPosition, character) then
		hardStop(humanoid)
		clearPath()
		return
	end

	forceJumpIfNeeded(humanoid, root, waypoint, character)

	if flatDirection.Magnitude > 0 then
		tryClimbObstacle(humanoid, root, character, flatDirection)
	end

	humanoid:MoveTo(nextPosition)
end

RunService.RenderStepped:Connect(function()
	if not LockEnabled then return end

	local myCharacter, myHumanoid, myRoot = getCharacter(LocalPlayer)

	if not myCharacter or not myHumanoid or not myRoot then
		return
	end

	if checkIfStuck(myRoot) then
		clearPath()
		lastPathCalculation = 0
	end

	if not isFootprintSafe(myRoot.Position, myCharacter, myRoot.Position.Y) then
		hardStop(myHumanoid)
		clearPath()
		return
	end

	local targetPlayer = getClosestPlayer()

	if not targetPlayer then
		clearPath()
		hardStop(myHumanoid)
		return
	end

	local targetCharacter, targetHumanoid, targetRoot = getCharacter(targetPlayer)

	if not targetCharacter or not targetHumanoid or not targetRoot then
		clearPath()
		hardStop(myHumanoid)
		return
	end

	local targetPart = targetCharacter:FindFirstChild(AimPart)

	if targetPart then
		Camera.CFrame = CFrame.new(Camera.CFrame.Position, targetPart.Position)
	end

	local distanceToTarget = (targetRoot.Position - myRoot.Position).Magnitude

	if distanceToTarget >= DesiredDistance - DistanceTolerance and distanceToTarget <= DesiredDistance + DistanceTolerance then
		hardStop(myHumanoid)
		return
	end

	local now = os.clock()

	if now - lastPathCalculation >= RecalculatePathDelay then
		lastPathCalculation = now

		local path, destination = findBestSafePositionAroundTarget(myRoot, targetRoot)

		if path and destination then
			currentPath = path
			currentDestination = destination
			waypoints = path:GetWaypoints()
			currentWaypointIndex = 1
		else
			clearPath()
			hardStop(myHumanoid)
			return
		end
	end

	if currentPath and #waypoints > 0 then
		followPath(myHumanoid, myRoot, myCharacter)
	else
		hardStop(myHumanoid)
	end
end)
