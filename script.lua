-- Mode Destruction Makima : lock caméra + déplacement fluide + anti-vide + auto item hotbar
-- T = activer / désactiver
-- Quand OFF : contrôle rendu au joueur

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

--// Activation

local ScriptEnabled = true

--// Auto prise en main item hotbar / backpack

local AutoEquipFirstItem = true
local AutoEquipCooldown = 0.3
local lastAutoEquip = 0

--// Réglages cible

local AimPart = "HumanoidRootPart"
local MaxTargetDistance = 300

local DesiredDistance = 39
local DistanceTolerance = 4

--// Optimisation

local TargetUpdateRate = 0.35
local lastTargetUpdate = 0
local currentTargetPlayer = nil

--// Mouvement

local MovePower = 1

--// Anti-vide

local GroundCheckDistance = 10
local GroundCheckDepth = 50
local GroundCheckHeight = 7
local EdgeSafetyRadius = 1.4

--// Directions alternatives

local SideCheckAngle = 35
local StrongSideCheckAngle = 70

--// Obstacle / mur

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

local function stopMovement()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		humanoid:Move(Vector3.zero, false)
	end

	Camera.CameraType = Enum.CameraType.Custom
end

local function autoEquipFirstTool()
	if not AutoEquipFirstItem then
		return
	end

	local now = os.clock()

	if now - lastAutoEquip < AutoEquipCooldown then
		return
	end

	lastAutoEquip = now

	local character = LocalPlayer.Character
	local backpack = LocalPlayer:FindFirstChild("Backpack")

	if not character or not backpack then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")

	if not humanoid then
		return
	end

	-- Si un item est déjà équipé, on ne touche pas
	local equippedTool = character:FindFirstChildOfClass("Tool")
	if equippedTool then
		return
	end

	-- Prend le premier Tool trouvé dans la hotbar/backpack
	for _, item in ipairs(backpack:GetChildren()) do
		if item:IsA("Tool") then
			humanoid:EquipTool(item)
			return
		end
	end
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end

	if input.KeyCode == Enum.KeyCode.T then
		ScriptEnabled = not ScriptEnabled

		if not ScriptEnabled then
			currentTargetPlayer = nil
			stopMovement()
		end
	end
end)

local function getClosestPlayer()
	local _, _, myRoot = getCharacter(LocalPlayer)
	if not myRoot then return nil end

	local closestPlayer = nil
	local closestDistance = MaxTargetDistance

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local _, _, otherRoot = getCharacter(player)

			if otherRoot then
				local distance = (otherRoot.Position - myRoot.Position).Magnitude

				if distance < closestDistance then
					closestDistance = distance
					closestPlayer = player
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

	return Vector3.new(
		direction.X * cos - direction.Z * sin,
		0,
		direction.X * sin + direction.Z * cos
	)
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
		rotateDirection(flatWanted, 110),
		rotateDirection(flatWanted, -110),
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

	return result and result.Instance and result.Instance.CanCollide
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
	if not myCharacter or not myHumanoid or not myRoot then
		return
	end

	autoEquipFirstTool()

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

	if targetPart then
		Camera.CFrame = CFrame.new(Camera.CFrame.Position, targetPart.Position)
	end

	local myPosition = myRoot.Position
	local targetPosition = targetRoot.Position

	local flatTargetPosition = Vector3.new(
		targetPosition.X,
		myPosition.Y,
		targetPosition.Z
	)

	local directionToTarget = flatTargetPosition - myPosition
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
