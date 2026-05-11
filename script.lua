-- Mode Destruction Makima : lock caméra + déplacement fluide + anti-vide + auto equip + fuite dégâts vers centre map
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

--// Auto sélection item hotbar / backpack

local AutoEquipSlot1 = true
local AutoEquipCooldown = 0.3
local lastAutoEquip = 0

--// Détection dégâts et fuite vers centre de map

local DamageEscapeEnabled = true
local DamageEscapeDuration = 4
local DamageEscapeDistance = 12

local lastHealth = nil
local lastDamageTime = -math.huge

--// Centre automatique de toute la map

local AutoMapCenterEnabled = true
local MapCenterScanCooldown = 3
local lastMapCenterScan = 0
local currentMapCenter = nil

local MinGroundSize = 12
local MaxGroundHeight = 12

--// Raycasts

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude

--// Fonctions personnage

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

--// Auto equip premier item

local function autoEquipFirstTool()
	if not AutoEquipSlot1 then
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

	local equippedTool = character:FindFirstChildOfClass("Tool")

	if equippedTool then
		return
	end

	for _, item in ipairs(backpack:GetChildren()) do
		if item:IsA("Tool") then
			humanoid:EquipTool(item)
			break
		end
	end
end

--// T pour ON / OFF

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

--// Cible proche

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

--// Sol / anti-vide

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

--// Mur / obstacle

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

--// Détection dégâts

local function updateDamageState(humanoid)
	if not DamageEscapeEnabled then
		return
	end

	if lastHealth == nil then
		lastHealth = humanoid.Health
		return
	end

	if humanoid.Health < lastHealth then
		lastDamageTime = os.clock()
	end

	lastHealth = humanoid.Health
end

local function isEscapingDamage()
	if not DamageEscapeEnabled then
		return false
	end

	return os.clock() - lastDamageTime <= DamageEscapeDuration
end

--// Centre global de la map

local function isMapGroundPart(part)
	if not part:IsA("BasePart") then
		return false
	end

	if not part.CanCollide then
		return false
	end

	if part.Transparency >= 1 then
		return false
	end

	if part.Size.Magnitude < MinGroundSize then
		return false
	end

	local horizontalSize = math.max(part.Size.X, part.Size.Z)

	if horizontalSize < MinGroundSize then
		return false
	end

	-- Ignore les murs très verticaux
	if part.Size.Y > MaxGroundHeight and part.Size.Y > part.Size.X and part.Size.Y > part.Size.Z then
		return false
	end

	-- Ignore les personnages
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return false
	end

	return true
end

local function updateGlobalMapCenter()
	if not AutoMapCenterEnabled then
		return
	end

	local now = os.clock()

	if now - lastMapCenterScan < MapCenterScanCooldown then
		return
	end

	lastMapCenterScan = now

	local totalWeight = 0
	local weightedPosition = Vector3.zero

	for _, object in ipairs(Workspace:GetDescendants()) do
		if isMapGroundPart(object) then
			local area = object.Size.X * object.Size.Z

			weightedPosition += object.Position * area
			totalWeight += area
		end
	end

	if totalWeight > 0 then
		currentMapCenter = weightedPosition / totalWeight
	end
end

local function getDirectionToGlobalMapCenter(root)
	if not currentMapCenter then
		return Vector3.zero
	end

	local rootPosition = root.Position

	local flatCenter = Vector3.new(
		currentMapCenter.X,
		rootPosition.Y,
		currentMapCenter.Z
	)

	local direction = flatCenter - rootPosition

	if direction.Magnitude <= DamageEscapeDistance then
		return Vector3.zero
	end

	return direction.Unit
end

--// Boucle principale

RunService.RenderStepped:Connect(function()
	if not ScriptEnabled then
		return
	end

	local now = os.clock()

	local myCharacter, myHumanoid, myRoot = getCharacter(LocalPlayer)
	if not myCharacter or not myHumanoid or not myRoot then
		return
	end

	updateDamageState(myHumanoid)
	updateGlobalMapCenter()
	autoEquipFirstTool()

	-- Recherche de cible allégée
	if now - lastTargetUpdate >= TargetUpdateRate then
		lastTargetUpdate = now
		currentTargetPlayer = getClosestPlayer()
	end

	local targetPlayer = currentTargetPlayer

	-- Caméra lock si cible existante
	if targetPlayer then
		local targetCharacter, _, targetRoot = getCharacter(targetPlayer)

		if targetCharacter and targetRoot then
			local targetPart = targetCharacter:FindFirstChild(AimPart)

			if targetPart then
				Camera.CFrame = CFrame.new(Camera.CFrame.Position, targetPart.Position)
			end
		else
			currentTargetPlayer = nil
		end
	end

	local wantedDirection = Vector3.zero

	-- PRIORITÉ 1 : si le joueur prend des dégâts, il va vers le centre global de la map
	if isEscapingDamage() then
		wantedDirection = getDirectionToGlobalMapCenter(myRoot)
	end

	-- PRIORITÉ 2 : sinon il garde la distance avec la cible
	if wantedDirection.Magnitude <= 0 then
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

		if distance > DesiredDistance + DistanceTolerance then
			wantedDirection = directionToTarget.Unit

		elseif distance < DesiredDistance - DistanceTolerance then
			wantedDirection = -directionToTarget.Unit

		else
			myHumanoid:Move(Vector3.zero, false)
			return
		end
	end

	local safeDirection = chooseSafeDirection(myRoot, myCharacter, wantedDirection)

	if safeDirection.Magnitude > 0 then
		tryJumpObstacle(myHumanoid, myRoot, myCharacter, safeDirection)
		myHumanoid:Move(safeDirection * MovePower, false)
	else
		myHumanoid:Move(Vector3.zero, false)
	end
end)
