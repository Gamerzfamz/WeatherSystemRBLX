--// Services (alphabetical order per Roblox style guide)
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// Asset references
-- direct indexing for ReplicatedStorage assets since they're guaranteed to exist at runtime
local Assets = ReplicatedStorage.WeatherAssets
local Skys = Assets.Skys
local Sounds = Assets.Sounds
local VFX = Assets.VFX

--// Effect templates
local rainTemplate = VFX.Rain

--// Sound templates
local lightningSoundTemplate = Sounds.Thunder
local thunderSoundTemplate = Sounds.Thunder
local rainSoundTemplate = Sounds.Rain

--// Weather configuration
local weatherTypes = {"Clear", "Rain", "Thunder"}
local weatherWeights = {
	Clear = 5,
	Rain = 2,
	Thunder = 2,
}

--// Configuration constants (LOUD_SNAKE_CASE per Roblox style guide)
local RAIN_HEIGHT_OFFSET = 40
local RAIN_FOLLOW_SPEED = 0.15
local LIGHTNING_MIN_STRIKES = 3
local LIGHTNING_MAX_STRIKES = 7
local LIGHTNING_FORK_DEPTH = 6
local LIGHTNING_SEGMENT_LENGTH = 4
local LIGHTNING_SEGMENT_WIDTH = 0.2
local LIGHTNING_SPAWN_RADIUS = 20
local LIGHTNING_HEIGHT_MIN = 10
local LIGHTNING_HEIGHT_MAX = 20
local LIGHTNING_BRANCH_ANGLE = math.rad(30)
local THUNDER_DELAY_MIN = 10
local THUNDER_DELAY_MAX = 20
local LIGHTNING_DURATION = 4
local LIGHTNING_FADE_TIME = 0.5
local SOUND_ROLLOFF_DISTANCE = 100
local THUNDER_ROLLOFF_DISTANCE = 150
local RAIN_MUTE_RADIUS = 50
local WEATHER_DURATION_MIN = 60
local WEATHER_DURATION_MAX = 180

--// State management
local currentWeather = nil
local rainEffects = {}
local thunderActive = false
local thunderThread = nil
local activeStrikes = {}
local rainAmbience = nil

--[[
	RainEffect class using metatables
	Each instance manages one player's rain effect with proper cleanup
]]
local RainEffect = {}
RainEffect.__index = RainEffect

function RainEffect.new(player)
	local self = setmetatable({}, RainEffect)
	
	self.player = player
	self.part = rainTemplate:Clone()
	self.part.Anchored = true
	self.part.CanCollide = false
	self.part.Parent = Workspace
	
	-- cache all particle emitters for later control
	-- this allows us to properly stop emission before destroying the part
	self.emitters = {}
	for _, descendant in ipairs(self.part:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			table.insert(self.emitters, descendant)
			descendant.Enabled = true
		end
	end
	
	self:updatePosition()
	
	return self
end

-- uses lerp to smoothly interpolate position instead of instant teleportation
-- this creates a natural following effect as the player moves around
function RainEffect:updatePosition()
	local character = self.player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	
	if hrp then
		local targetPos = hrp.Position + Vector3.new(0, RAIN_HEIGHT_OFFSET, 0)
		-- lerp blends current position toward target by RAIN_FOLLOW_SPEED factor
		local newPos = self.part.Position:Lerp(targetPos, RAIN_FOLLOW_SPEED)
		self.part.CFrame = CFrame.new(newPos)
	else
		-- move offscreen when character doesn't exist (respawning, etc)
		self.part.CFrame = CFrame.new(0, 1000, 0)
	end
end

-- proper cleanup sequence: disable emitters, wait for particles to fade, then destroy
-- if you destroy immediately, particles keep emitting which looks wrong
function RainEffect:destroy()
	for _, emitter in ipairs(self.emitters) do
		if emitter then
			emitter.Enabled = false
		end
	end
	
	-- brief wait allows existing particles to finish their lifetime
	task.wait(0.1)
	
	if self.part and self.part.Parent then
		self.part:Destroy()
	end
	
	-- nil out references to help garbage collector
	self.emitters = nil
	self.part = nil
	self.player = nil
end

--[[
	LightningStrike class manages individual bolt lifecycle
	Uses CFrame math for realistic angular branching
]]
local LightningStrike = {}
LightningStrike.__index = LightningStrike

function LightningStrike.new(position)
	local self = setmetatable({}, LightningStrike)
	
	self.position = position
	self.segments = {}
	self.sounds = {}
	self.startTime = os.clock()
	self.active = true
	
	self:generateBolt()
	self:createAudio()
	
	-- heartbeat connection handles fade effect and cleanup timing
	self.connection = RunService.Heartbeat:Connect(function()
		self:update()
	end)
	
	return self
end

-- recursive function builds branching structure
-- uses CFrame.Angles to rotate direction vectors for natural-looking forks
function LightningStrike:generateBranch(startPos, direction, depth)
	if depth > LIGHTNING_FORK_DEPTH then
		return
	end
	
	local endPos = startPos + (direction.Unit * LIGHTNING_SEGMENT_LENGTH)
	
	-- create segment part
	local segment = Instance.new("Part")
	local length = (endPos - startPos).Magnitude
	segment.Size = Vector3.new(LIGHTNING_SEGMENT_WIDTH, length, LIGHTNING_SEGMENT_WIDTH)
	segment.Anchored = true
	segment.CanCollide = false
	segment.Material = Enum.Material.Neon
	segment.Color = Color3.new(1, 1, 1)
	segment.Transparency = 0.25
	segment.CastShadow = false
	
	-- CFrame.lookAt orients the part to point from start to end
	-- offset by -length/2 on Z axis centers it between the two points
	segment.CFrame = CFrame.lookAt(startPos, endPos) * CFrame.new(0, 0, -length / 2)
	segment.Parent = Workspace
	
	table.insert(self.segments, segment)
	
	-- main branch has higher continuation probability to form a "trunk"
	if math.random() < 0.7 then
		-- CFrame.Angles creates rotation matrix, multiply with direction to deviate path
		local branchAngle = CFrame.Angles(
			math.random() * LIGHTNING_BRANCH_ANGLE - LIGHTNING_BRANCH_ANGLE / 2,
			math.random() * LIGHTNING_BRANCH_ANGLE - LIGHTNING_BRANCH_ANGLE / 2,
			0
		)
		local newDirection = (branchAngle * CFrame.new(direction)).Position
		self:generateBranch(endPos, newDirection, depth + 1)
	end
	
	-- side forks have lower probability to keep branching sparse
	if math.random() < 0.5 then
		local forkAngle = CFrame.Angles(
			math.random() * math.pi - math.pi / 2,
			math.random() * math.pi * 2,
			0
		)
		local forkDirection = (forkAngle * CFrame.new(0, -1, 0)).Position
		self:generateBranch(endPos, forkDirection, depth + 1)
	end
end

function LightningStrike:generateBolt()
	local startDirection = Vector3.new(0, -1, 0)
	self:generateBranch(self.position, startDirection, 1)
end

-- creates two sounds with different rolloff distances
-- lightning is sharp/close, thunder rumbles further
function LightningStrike:createAudio()
	local lightningSound = lightningSoundTemplate:Clone()
	lightningSound.Parent = Workspace
	lightningSound.Position = self.position
	lightningSound.RollOffMode = Enum.RollOffMode.Linear
	lightningSound.MaxDistance = SOUND_ROLLOFF_DISTANCE
	lightningSound:Play()
	table.insert(self.sounds, lightningSound)
	
	local thunderSound = thunderSoundTemplate:Clone()
	thunderSound.Parent = Workspace
	thunderSound.Position = self.position
	thunderSound.RollOffMode = Enum.RollOffMode.Linear
	thunderSound.MaxDistance = THUNDER_ROLLOFF_DISTANCE
	thunderSound:Play()
	table.insert(self.sounds, thunderSound)
end

-- runs every frame to handle volume updates, rain muting, fade effect, and cleanup
function LightningStrike:update()
	local elapsed = os.clock() - self.startTime
	
	self:updateSoundVolumes()
	self:updateRainMuting()
	
	-- fade out in the last half-second before cleanup
	-- linear interpolation from 0.25 to 1.0 transparency
	if elapsed > LIGHTNING_DURATION - LIGHTNING_FADE_TIME then
		local fadeProgress = (elapsed - (LIGHTNING_DURATION - LIGHTNING_FADE_TIME)) / LIGHTNING_FADE_TIME
		for _, segment in ipairs(self.segments) do
			if segment and segment.Parent then
				segment.Transparency = 0.25 + (0.75 * fadeProgress)
			end
		end
	end
	
	if elapsed > LIGHTNING_DURATION then
		self:destroy()
	end
end

-- adjusts volume based on distance to nearest player
-- closer players hear louder sounds
function LightningStrike:updateSoundVolumes()
	local closestDist = math.huge
	
	for _, player in ipairs(Players:GetPlayers()) do
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if hrp then
			local dist = (hrp.Position - self.position).Magnitude
			closestDist = math.min(closestDist, dist)
		end
	end
	
	-- linear falloff clamped between 0 and 1
	for _, sound in ipairs(self.sounds) do
		if sound and sound.Parent then
			local volume = math.clamp(1 - closestDist / SOUND_ROLLOFF_DISTANCE, 0, 1)
			sound.Volume = volume
		end
	end
end

-- simulates thunder drowning out rain sound
-- if any player is close to this strike, rain ambience gets muted
function LightningStrike:updateRainMuting()
	if not rainAmbience then
		return
	end
	
	for _, player in ipairs(Players:GetPlayers()) do
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if hrp and (hrp.Position - self.position).Magnitude <= RAIN_MUTE_RADIUS then
			rainAmbience.Volume = 0
			return
		end
	end
	
	rainAmbience.Volume = 1
end

function LightningStrike:destroy()
	self.active = false
	
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
	
	for _, segment in ipairs(self.segments) do
		if segment and segment.Parent then
			segment:Destroy()
		end
	end
	
	for _, sound in ipairs(self.sounds) do
		if sound and sound.Parent then
			sound:Stop()
			sound:Destroy()
		end
	end
	
	self.segments = nil
	self.sounds = nil
end

--[[
	WeatherManager functions
]]

local function setSky(weatherType)
	local existingSky = Lighting:FindFirstChildOfClass("Sky")
	if existingSky then
		existingSky:Destroy()
	end
	
	local skyTemplate = Skys:FindFirstChild(weatherType)
	if skyTemplate then
		skyTemplate:Clone().Parent = Lighting
	end
end

-- iterates through dictionary and calls destroy method on each effect
-- this properly disables particle emitters before destroying parts
local function clearRain()
	for player, effect in pairs(rainEffects) do
		effect:destroy()
		rainEffects[player] = nil
	end
	
	if rainAmbience then
		rainAmbience:Stop()
		rainAmbience:Destroy()
		rainAmbience = nil
	end
end

local function createRainForPlayer(player)
	if rainEffects[player] then
		return
	end
	
	rainEffects[player] = RainEffect.new(player)
end

-- called every second to keep rain following players smoothly
local function updateRainPositions()
	for player, effect in pairs(rainEffects) do
		if effect then
			effect:updatePosition()
		end
	end
end

local function stopThunder()
	thunderActive = false
	
	if thunderThread then
		task.cancel(thunderThread)
		thunderThread = nil
	end
	
	-- clean up all active strikes using their destroy methods
	for _, strike in ipairs(activeStrikes) do
		if strike and strike.active then
			strike:destroy()
		end
	end
	
	activeStrikes = {}
end

-- uses polar coordinates via CFrame rotation to spawn in circle around player
-- this creates more natural-looking strike distribution than random box offsets
local function spawnLightningNearPlayer(player)
	local character = player.Character
	if not character then
		return
	end
	
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	
	-- rotate around Y axis by random angle, then offset on Z to get circular positioning
	local angle = math.random() * math.pi * 2
	local distance = math.random() * LIGHTNING_SPAWN_RADIUS
	local offsetCFrame = CFrame.new(hrp.Position) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, -distance)
	local spawnPos = offsetCFrame.Position + Vector3.new(0, math.random(LIGHTNING_HEIGHT_MIN, LIGHTNING_HEIGHT_MAX), 0)
	
	local strike = LightningStrike.new(spawnPos)
	table.insert(activeStrikes, strike)
end

-- infinite loop that periodically spawns lightning strikes
-- runs in separate thread so it doesn't block main script
local function thunderCycle()
	while thunderActive do
		local players = Players:GetPlayers()
		
		if #players > 0 then
			local strikeCount = math.min(#players, math.random(LIGHTNING_MIN_STRIKES, LIGHTNING_MAX_STRIKES))
			local usedIndices = {}
			
			-- spawn multiple strikes at different players simultaneously
			for _ = 1, strikeCount do
				local idx
				repeat
					idx = math.random(1, #players)
				until not usedIndices[idx]
				usedIndices[idx] = true
				
				spawnLightningNearPlayer(players[idx])
			end
		end
		
		task.wait(math.random(THUNDER_DELAY_MIN, THUNDER_DELAY_MAX))
	end
end

local function startThunder()
	if thunderActive then
		return
	end
	
	thunderActive = true
	thunderThread = task.spawn(thunderCycle)
end

local function clearSounds()
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Sound") then
			child:Stop()
			child:Destroy()
		end
	end
end

-- main weather application function
-- coordinates all subsystems (sky, rain, thunder, audio)
local function applyWeather(weatherType)
	if weatherType == currentWeather then
		return
	end
	
	setSky(weatherType)
	clearSounds()
	stopThunder()
	clearRain()
	
	if weatherType == "Clear" then
		currentWeather = "Clear"
		
	elseif weatherType == "Rain" then
		-- create rain effect for each existing player
		for _, player in ipairs(Players:GetPlayers()) do
			createRainForPlayer(player)
		end
		
		rainAmbience = rainSoundTemplate:Clone()
		rainAmbience.Parent = Workspace
		rainAmbience.Looped = true
		rainAmbience.Volume = 1
		rainAmbience:Play()
		
		currentWeather = "Rain"
		
	elseif weatherType == "Thunder" then
		-- thunder weather includes rain plus lightning strikes
		for _, player in ipairs(Players:GetPlayers()) do
			createRainForPlayer(player)
		end
		
		rainAmbience = rainSoundTemplate:Clone()
		rainAmbience.Parent = Workspace
		rainAmbience.Looped = true
		rainAmbience.Volume = 1
		rainAmbience:Play()
		
		startThunder()
		currentWeather = "Thunder"
	end
end

-- weighted random selection algorithm
-- higher weight values increase probability of selection
local function chooseWeather()
	local totalWeight = 0
	for _, weight in pairs(weatherWeights) do
		totalWeight += weight
	end
	
	local roll = math.random() * totalWeight
	local cumulative = 0
	
	-- iterate through weights, when cumulative exceeds roll we've hit that weather
	for _, weatherType in ipairs(weatherTypes) do
		cumulative += weatherWeights[weatherType]
		if roll <= cumulative then
			return weatherType
		end
	end
	
	return weatherTypes[#weatherTypes]
end

--// Event handlers

-- new players get rain if the current weather includes it
Players.PlayerAdded:Connect(function(player)
	if currentWeather == "Rain" or currentWeather == "Thunder" then
		createRainForPlayer(player)
	end
end)

-- cleanup when player leaves
Players.PlayerRemoving:Connect(function(player)
	if rainEffects[player] then
		rainEffects[player]:destroy()
		rainEffects[player] = nil
	end
end)

--// Main loop

while true do
	local weather = chooseWeather()
	
	-- reroll until we get different weather from current
	while weather == currentWeather do
		weather = chooseWeather()
	end
	
	applyWeather(weather)
	
	-- weather lasts for random duration, rain positions update every second
	local duration = math.random(WEATHER_DURATION_MIN, WEATHER_DURATION_MAX)
	for _ = 1, duration do
		updateRainPositions()
		task.wait(1)
	end
end
