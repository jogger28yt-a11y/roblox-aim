-- Version optimisée : lock caméra + garde distance + évite le vide
-- T = active / désactive le script
-- Quand OFF : contrôle rendu au joueur

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

--// Activation

local ScriptEnabled = true

--// Réglages cible

local AimPart = "HumanoidRootPart"
local MaxTargetDistance = 300

local DesiredDistance = 39
local DistanceTolerance = 2

--// Optimisation

local MovementUpdateRate = 0.08
local TargetUpdateRate = 0.25

local lastMovementUpdate = 0
local lastTargetUpdate = 0
local currentTargetPlayer = nil

--// Mouvement

local MovePower = 1

--// Anti-vide léger

local GroundCheckDistance = 9
local GroundCheckDepth = 45
local GroundCheckHeight = 6
local SideCheckAngle = 45
local StrongSideCheckAngle = 90

local EdgeSafetyRadius = 1.3

--// Mur / obstacle

local WallCheckDistance = 4
local WallJumpCooldown = 0.35
local lastWallJump = 0

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude

local function getCharacter(player)
	local character = player.Character
	if not character then return nil end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")

	if not humanoid or not root or humanoid.Health <= 0 then
		return nil
	end

	return character, humanoid, root
end

local function stopScriptMovement()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		humanoid:Move(Vector3.zero, false)
	end

	Camera.CameraType = Enum.CameraType.Custom
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end

	if input.KeyCode == Enum.KeyCode.T then
		ScriptEnabled = not ScriptEnabled
		stopScriptMovement()

		if not ScriptEnabled then
			currentTargetPlayer = nil
		end
	end
end)

local function getClosestPlayer()
	local _, _, myRoot = getCharacter(LocalPlayer)
	if not myRoot then return nil end

	local closestPlayer = nil
	local closestDistance = MaxTargetDistance

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= LocalPlayer then
			local _, _, otherRoot = getCharacter(otherPlayer)

			if otherRoot then
				local distance = (otherRoot.Position - myRoot.Position).Magnitude

				if distance < closestDistance then
					closestDistance = distance
					closestPlayer = otherPlayer
				end
			end
		end
	end

	return closestPlayer
end

local function hasGround(position, character)
	rayParams.FilterDescendantsInstances = { character }

	local origin = position + Vector3.new(0, GroundCheckHeight, 0)
	local direction = Vector3.new(0, -GroundCheckDepth, 0)

	local result = Workspace:Raycast(origin, direction, rayParams)

	return result ~= nil
end

local function isPositionSafe(position, character)
	local checks = {
		Vector3.new(0, 0, 0),
		Vector3.new(EdgeSafetyRadius, 0, 0),
		Vector3.new(-EdgeSafetyRadius, 0, 0),
		Vector3.new(0, 0, EdgeSafetyRadius),
		Vector3.new(0, 0, -EdgeSafetyRadius),
	}

	for _, offset in ipairs(checks) do
		if not hasGround(position + offset, character) then
			return false
		end
	end

	return true
end

local function rotateDirection(direction, degrees)
	local radians = math.rad(degrees)
	local cos = math.cos(radians)
	local sin = math.sin(radians)

	local x = direction.X * cos - direction.Z * sin
	local z = direction.X * sin + direction.Z * cos

	return Vector3.new(x, 0, z)
end

local function chooseSafeDirection(root, character, wantedDirection)
	if wantedDirection.Magnitude <= 0 then
		return Vector3.zero
	end

	local flatWanted = Vector3.new(wantedDirection.X, 0, wantedDirection.Z)

	if flatWanted.Magnitude <= 0 then
		return Vector3.zero
	end

	flatWanted = flatWanted.Unit

	local directionsToTry = {
		flatWanted,
		rotateDirection(flatWanted, SideCheckAngle),
		rotateDirection(flatWanted, -SideCheckAngle),
		rotateDirection(flatWanted, StrongSideCheckAngle),
		rotateDirection(flatWanted, -StrongSideCheckAngle),
		rotateDirection(flatWanted, 135),
		rotateDirection(flatWanted, -135),
	}

	for _, direction in ipairs(directionsToTry) do
		local checkPosition = root.Position + direction.Unit * GroundCheckDistance

		if isPositionSafe(checkPosition, character) then
			return direction.Unit
		end
	end

	return Vector3.zero
end

local function checkWallAhead(root, character, direction)
	if direction.Magnitude <= 0 then
		return false
	end

	wallParams.FilterDescendantsInstances = { character }

	local flatDirection = Vector3.new(direction.X, 0, direction.Z)

	if flatDirection.Magnitude <= 0 then
		return false
	end

	local origin = root.Position + Vector3.new(0, 2, 0)
	local rayDirection = flatDirection.Unit * WallCheckDistance

	local result = Workspace:Raycast(origin, rayDirection, wallParams)

	if result and result.Instance and result.Instance.CanCollide then
		return true
	end

	return false
end

local function tryJumpObstacle(humanoid, root, character, direction)
	local now = os.clock()

	if now - lastWallJump < WallJumpCooldown then
		return
	end

	if checkWallAhead(root, character, direction) then
		lastWallJump = now
		humanoid.Jump = true
	end
end

RunService.RenderStepped:Connect(function()
	if not ScriptEnabled then
		return
	end

	local now = os.clock()

	local myCharacter, myHumanoid, myRoot = getCharacter(LocalPlayer)
	if not myCharacter or not myHumanoid or not myRoot then return end

	-- Recherche de cible moins souvent pour éviter le lag
	if now - lastTargetUpdate >= TargetUpdateRate then
		lastTargetUpdate = now
		currentTargetPlayer = getClosestPlayer()
	end

	local targetPlayer = currentTargetPlayer

	if not targetPlayer then
		myHumanoid:Move(Vector3.zero, false)
		return
	end

	local targetCharacter, _, targetRoot = getCharacter(targetPlayer)

	if not targetCharacter or not targetRoot then
		currentTargetPlayer = nil
		myHumanoid:Move(Vector3.zero, false)
		return
	end

	local targetPart = targetCharacter:FindFirstChild(AimPart)

	-- Caméra toujours fluide
	if targetPart then
		Camera.CFrame = CFrame.new(Camera.CFrame.Position, targetPart.Position)
	end

	-- Déplacement moins souvent pour éviter les freeze
	if now - lastMovementUpdate < MovementUpdateRate then
		return
	end

	lastMovementUpdate = now

	local myPos = myRoot.Position
	local targetPos = targetRoot.Position

	local flatTargetPos = Vector3.new(targetPos.X, myPos.Y, targetPos.Z)
	local directionToTarget = flatTargetPos - myPos
	local distance = directionToTarget.Magnitude

	if distance <= 0 then
		myHumanoid:Move(Vector3.zero, false)
		return
	end

	local wantedDirection = Vector3.zero

	if distance > DesiredDistance + DistanceTolerance then
		wantedDirection = directionToTarget.Unit

	elseif distance < DesiredDistance - DistanceTolerance then
		wantedDirection = -directionToTarget.Unit

	else
		myHumanoid:Move(Vector3.zero, false)
		return
	end

	local safeDirection = chooseSafeDirection(myRoot, myCharacter, wantedDirection)

	if safeDirection.Magnitude > 0 then
		tryJumpObstacle(myHumanoid, myRoot, myCharacter, safeDirection)
		myHumanoid:Move(safeDirection * MovePower, false)
	else
		myHumanoid:Move(Vector3.zero, false)
	end
end)
