--// Services
local Lighting = game:GetService("Lighting") -- gets the Lighting service which controls sky and ambient
local Players = game:GetService("Players") -- gets the Players service to track players in the game
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- gets ReplicatedStorage where assets are stored
local RunService = game:GetService("RunService") -- gets RunService for frame-by-frame updates
local Workspace = game:GetService("Workspace") -- gets Workspace where 3D objects exist

--// Asset references
local Assets = ReplicatedStorage.WeatherAssets -- folder containing all weather-related assets
local Skys = Assets.Skys -- folder containing different sky assets for each weather type
local Sounds = Assets.Sounds -- folder containing audio files for weather sounds
local VFX = Assets.VFX -- folder containing visual effect templates

--// Effect templates
local rainTemplate = VFX.Rain -- template part with particle emitters for rain effect

--// Sound templates
local lightningSoundTemplate = Sounds.Thunder -- sound that plays when lightning strikes (sharp crack)
local thunderSoundTemplate = Sounds.Thunder -- sound that plays after lightning (deep rumble)
local rainSoundTemplate = Sounds.Rain -- looping ambient rain sound

--// Weather configuration
local weatherTypes = {"Clear", "Rain", "Thunder"} -- array of all available weather types
local weatherWeights = { -- dictionary mapping weather types to their probability weights
	Clear = 5, -- clear weather is most common (5/9 chance)
	Rain = 2, -- rain has medium probability (2/9 chance)
	Thunder = 2, -- thunder has same probability as rain (2/9 chance)
}

--// Configuration constants
local RAIN_HEIGHT_OFFSET = 40 -- studs above player where rain spawns
local RAIN_FOLLOW_SPEED = 0.15 -- lerp factor for smooth rain following (0-1 range)
local LIGHTNING_MIN_STRIKES = 3 -- minimum lightning bolts per thunder cycle
local LIGHTNING_MAX_STRIKES = 7 -- maximum lightning bolts per thunder cycle
local LIGHTNING_FORK_DEPTH = 6 -- how many times lightning can branch recursively
local LIGHTNING_SEGMENT_LENGTH = 4 -- length in studs of each lightning segment
local LIGHTNING_SEGMENT_WIDTH = 0.2 -- width in studs of lightning segments
local LIGHTNING_SPAWN_RADIUS = 20 -- radius around player where lightning can spawn
local LIGHTNING_HEIGHT_MIN = 10 -- minimum height above player for lightning spawn
local LIGHTNING_HEIGHT_MAX = 20 -- maximum height above player for lightning spawn
local LIGHTNING_BRANCH_ANGLE = math.rad(30) -- max angle deviation for lightning branches (converted to radians)
local THUNDER_DELAY_MIN = 10 -- minimum seconds between thunder cycles
local THUNDER_DELAY_MAX = 20 -- maximum seconds between thunder cycles
local LIGHTNING_DURATION = 4 -- total seconds lightning stays visible
local LIGHTNING_FADE_TIME = 0.5 -- seconds to fade out lightning before removal
local SOUND_ROLLOFF_DISTANCE = 100 -- distance in studs where sounds reach minimum volume
local THUNDER_ROLLOFF_DISTANCE = 150 -- thunder travels further so it has longer rolloff
local RAIN_MUTE_RADIUS = 50 -- radius around lightning where rain sound gets muted
local WEATHER_DURATION_MIN = 60 -- minimum seconds each weather lasts
local WEATHER_DURATION_MAX = 180 -- maximum seconds each weather lasts

--// State management
local currentWeather = nil -- tracks what weather is currently active
local rainEffects = {} -- dictionary mapping players to their RainEffect objects
local thunderActive = false -- boolean flag indicating if thunder cycle is running
local thunderThread = nil -- reference to the thunder cycle thread for cancellation
local activeStrikes = {} -- array of all currently active LightningStrike objects
local rainAmbience = nil -- reference to the looping rain sound instance

--[[
	RainEffect class using metatables
	Each instance manages one player's rain effect with proper cleanup
]]
local RainEffect = {} -- table that will hold class methods
RainEffect.__index = RainEffect -- metatable setup so instances inherit from RainEffect table

function RainEffect.new(player) -- constructor function creates new RainEffect instance
	local self = setmetatable({}, RainEffect) -- creates empty table and sets RainEffect as its metatable
	
	self.player = player -- stores reference to the player this effect follows
	self.part = rainTemplate:Clone() -- clones the rain template to create unique instance
	self.part.Anchored = true -- anchors part so it doesn't fall due to gravity
	self.part.CanCollide = false -- makes part non-solid so players can walk through it
	self.part.Parent = Workspace -- parents to Workspace to make it visible in game
	
	-- find and cache all particle emitters in the rain part
	self.emitters = {} -- creates empty array to store emitter references
	for _, descendant in ipairs(self.part:GetDescendants()) do -- loops through all children and nested children
		if descendant:IsA("ParticleEmitter") then -- checks if this object is a ParticleEmitter
			table.insert(self.emitters, descendant) -- adds emitter to array for later control
			descendant.Enabled = true -- enables the emitter so particles start spawning
		end
	end
	
	self:updatePosition() -- immediately updates position to be above player
	
	return self -- returns the constructed object
end

-- lerp smoothly moves the rain part toward the player's position
-- creates a natural following effect rather than snapping instantly
function RainEffect:updatePosition() -- method to update rain position (: syntax passes self automatically)
	local character = self.player.Character -- gets the player's character model
	local hrp = character and character:FindFirstChild("HumanoidRootPart") -- gets the HumanoidRootPart if character exists
	
	if hrp then -- checks if we successfully got the HumanoidRootPart
		local targetPos = hrp.Position + Vector3.new(0, RAIN_HEIGHT_OFFSET, 0) -- calculates position above player
		-- blend current position with target position by the follow speed factor
		local newPos = self.part.Position:Lerp(targetPos, RAIN_FOLLOW_SPEED) -- interpolates between current and target
		self.part.CFrame = CFrame.new(newPos) -- sets the part's CFrame to the new position
	else -- if character or HumanoidRootPart doesn't exist
		-- move offscreen if the character is nil (dead, respawning, etc)
		self.part.CFrame = CFrame.new(0, 1000, 0) -- positions rain way up in sky where it's not visible
	end
end

-- destroys the rain effect with proper cleanup sequence
function RainEffect:destroy() -- cleanup method to remove this rain effect
	-- turn off emitters first to stop new particles from spawning
	for _, emitter in ipairs(self.emitters) do -- loops through all cached emitters
		if emitter then -- checks if emitter still exists
			emitter.Enabled = false -- disables emitter to stop particle generation
		end
	end
	
	-- short delay lets existing particles finish their lifetime naturally
	task.wait(0.1) -- waits 0.1 seconds for particles to fade out
	
	if self.part and self.part.Parent then -- checks if part still exists and is in the game
		self.part:Destroy() -- destroys the physical part from game
	end
	
	self.emitters = nil -- clears emitter references for garbage collection
	self.part = nil -- clears part reference for garbage collection
	self.player = nil -- clears player reference for garbage collection
end

--[[
	LightningStrike class manages individual bolt lifecycle
	Uses CFrame math for realistic angular branching
]]
local LightningStrike = {} -- table that will hold class methods
LightningStrike.__index = LightningStrike -- metatable setup for inheritance

function LightningStrike.new(position) -- constructor creates new lightning strike at given position
	local self = setmetatable({}, LightningStrike) -- creates new instance with LightningStrike metatable
	
	self.position = position -- stores spawn position of this lightning strike
	self.segments = {} -- array to store all visual segments of this bolt
	self.sounds = {} -- array to store audio instances for this strike
	self.startTime = os.clock() -- records current time for duration tracking
	self.active = true -- flag indicating this strike is still active
	
	self:generateBolt() -- creates the visual lightning segments
	self:createAudio() -- creates the audio for this strike
	
	-- heartbeat connection handles fade effect and cleanup timing
	self.connection = RunService.Heartbeat:Connect(function() -- connects to Heartbeat event (runs every frame)
		self:update() -- calls update method every frame
	end)
	
	return self -- returns the constructed lightning strike object
end

-- recursively builds the branching lightning structure
-- each branch can spawn additional branches based on probability
function LightningStrike:generateBranch(startPos, direction, depth) -- recursive function with position, direction, and depth
	if depth > LIGHTNING_FORK_DEPTH then -- checks if we've reached maximum recursion depth
		return -- stops recursion if max depth exceeded
	end
	
	local endPos = startPos + (direction.Unit * LIGHTNING_SEGMENT_LENGTH) -- calculates endpoint by adding direction vector
	
	-- create the part that represents this segment
	local segment = Instance.new("Part") -- creates new Part instance
	local length = (endPos - startPos).Magnitude -- calculates distance between start and end
	segment.Size = Vector3.new(LIGHTNING_SEGMENT_WIDTH, length, LIGHTNING_SEGMENT_WIDTH) -- sets size with calculated length
	segment.Anchored = true -- anchors so it doesn't fall
	segment.CanCollide = false -- makes non-solid
	segment.Material = Enum.Material.Neon -- sets material to Neon for glowing effect
	segment.Color = Color3.new(1, 1, 1) -- sets color to white
	segment.Transparency = 0.25 -- makes slightly transparent for realistic look
	segment.CastShadow = false -- disables shadows for performance
	
	-- orient the segment from start point to end point
	-- offset by -length/2 on Z to center it between the two positions
	segment.CFrame = CFrame.lookAt(startPos, endPos) * CFrame.new(0, 0, -length / 2) -- positions and orients segment
	segment.Parent = Workspace -- parents to Workspace to make visible
	
	table.insert(self.segments, segment) -- adds segment to array for later cleanup
	
	-- 70% chance to continue the main branch
	if math.random() < 0.7 then -- generates random number between 0 and 1, checks if less than 0.7
		-- rotate the direction slightly using CFrame.Angles
		local branchAngle = CFrame.Angles( -- creates rotation CFrame
			math.random() * LIGHTNING_BRANCH_ANGLE - LIGHTNING_BRANCH_ANGLE / 2, -- random X rotation within range
			math.random() * LIGHTNING_BRANCH_ANGLE - LIGHTNING_BRANCH_ANGLE / 2, -- random Y rotation within range
			0 -- no Z rotation
		)
		local newDirection = (branchAngle * CFrame.new(direction)).Position -- applies rotation to direction vector
		self:generateBranch(endPos, newDirection, depth + 1) -- recursive call with incremented depth
	end
	
	-- 50% chance to spawn a side fork
	if math.random() < 0.5 then -- generates random number, checks if less than 0.5
		local forkAngle = CFrame.Angles( -- creates rotation for side fork
			math.random() * math.pi - math.pi / 2, -- random X rotation
			math.random() * math.pi * 2, -- random Y rotation (full circle)
			0 -- no Z rotation
		)
		local forkDirection = (forkAngle * CFrame.new(0, -1, 0)).Position -- applies rotation to downward vector
		self:generateBranch(endPos, forkDirection, depth + 1) -- recursive call for side branch
	end
end

function LightningStrike:generateBolt() -- starts the bolt generation process
	local startDirection = Vector3.new(0, -1, 0) -- creates downward direction vector
	self:generateBranch(self.position, startDirection, 1) -- calls recursive function starting at depth 1
end

-- creates two sound instances with different rolloff properties
function LightningStrike:createAudio() -- method to create audio for this strike
	local lightningSound = lightningSoundTemplate:Clone() -- clones the lightning sound template
	lightningSound.Parent = Workspace -- parents to Workspace so it plays in 3D space
	lightningSound.Position = self.position -- sets position to strike location
	lightningSound.RollOffMode = Enum.RollOffMode.Linear -- uses linear volume falloff with distance
	lightningSound.MaxDistance = SOUND_ROLLOFF_DISTANCE -- sets maximum hearing distance
	lightningSound:Play() -- starts playing the sound
	table.insert(self.sounds, lightningSound) -- adds to sounds array for cleanup
	
	-- thunder has a longer max distance so it can be heard from further away
	local thunderSound = thunderSoundTemplate:Clone() -- clones thunder sound template
	thunderSound.Parent = Workspace -- parents to Workspace
	thunderSound.Position = self.position -- sets position to same location
	thunderSound.RollOffMode = Enum.RollOffMode.Linear -- uses linear falloff
	thunderSound.MaxDistance = THUNDER_ROLLOFF_DISTANCE -- thunder travels further
	thunderSound:Play() -- starts playing
	table.insert(self.sounds, thunderSound) -- adds to sounds array
end

-- runs every frame to manage volume, fading, and cleanup timing
function LightningStrike:update() -- update method called every frame
	local elapsed = os.clock() - self.startTime -- calculates how much time has passed since creation
	
	self:updateSoundVolumes() -- updates volumes based on player distance
	self:updateRainMuting() -- checks if rain should be muted
	
	-- gradually fade out the lightning in the last 0.5 seconds
	if elapsed > LIGHTNING_DURATION - LIGHTNING_FADE_TIME then -- checks if we're in fade period
		local fadeProgress = (elapsed - (LIGHTNING_DURATION - LIGHTNING_FADE_TIME)) / LIGHTNING_FADE_TIME -- calculates fade progress 0-1
		for _, segment in ipairs(self.segments) do -- loops through all segments
			if segment and segment.Parent then -- checks if segment still exists
				-- interpolate transparency from 0.25 to 1.0
				segment.Transparency = 0.25 + (0.75 * fadeProgress) -- gradually increases transparency
			end
		end
	end
	
	if elapsed > LIGHTNING_DURATION then -- checks if total duration has passed
		self:destroy() -- calls cleanup method
	end
end

-- calculates volume based on distance to closest player
function LightningStrike:updateSoundVolumes() -- method to update audio volumes
	local closestDist = math.huge -- starts with very large number (infinity)
	
	for _, player in ipairs(Players:GetPlayers()) do -- loops through all players in game
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart") -- gets player's HumanoidRootPart
		if hrp then -- checks if HumanoidRootPart exists
			local dist = (hrp.Position - self.position).Magnitude -- calculates distance between player and strike
			closestDist = math.min(closestDist, dist) -- updates closest distance if this is closer
		end
	end
	
	-- linear falloff formula
	for _, sound in ipairs(self.sounds) do -- loops through all sounds for this strike
		if sound and sound.Parent then -- checks if sound still exists
			local volume = math.clamp(1 - closestDist / SOUND_ROLLOFF_DISTANCE, 0, 1) -- calculates volume using linear falloff
			sound.Volume = volume -- sets the sound's volume
		end
	end
end

-- mutes rain ambience when any player is near this lightning strike
function LightningStrike:updateRainMuting() -- method to handle rain muting near lightning
	if not rainAmbience then -- checks if rain sound exists
		return -- exits early if no rain sound
	end
	
	for _, player in ipairs(Players:GetPlayers()) do -- loops through all players
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart") -- gets HumanoidRootPart
		if hrp and (hrp.Position - self.position).Magnitude <= RAIN_MUTE_RADIUS then -- checks if player is within mute radius
			rainAmbience.Volume = 0 -- mutes rain sound
			return -- exits function early since we found a close player
		end
	end
	
	rainAmbience.Volume = 1 -- restores rain volume if no players are close
end

function LightningStrike:destroy() -- cleanup method to remove this lightning strike
	self.active = false -- sets flag to inactive
	
	if self.connection then -- checks if Heartbeat connection exists
		self.connection:Disconnect() -- disconnects from Heartbeat to stop update loop
		self.connection = nil -- clears reference
	end
	
	for _, segment in ipairs(self.segments) do -- loops through all visual segments
		if segment and segment.Parent then -- checks if segment still exists in game
			segment:Destroy() -- destroys the segment part
		end
	end
	
	for _, sound in ipairs(self.sounds) do -- loops through all sounds
		if sound and sound.Parent then -- checks if sound still exists
			sound:Stop() -- stops the sound playback
			sound:Destroy() -- destroys the sound instance
		end
	end
	
	self.segments = nil -- clears segments array for garbage collection
	self.sounds = nil -- clears sounds array for garbage collection
end

--[[
	WeatherManager functions
]]

local function setSky(weatherType) -- function to change the sky based on weather
	local existingSky = Lighting:FindFirstChildOfClass("Sky") -- finds current Sky object in Lighting
	if existingSky then -- checks if a sky already exists
		existingSky:Destroy() -- destroys old sky
	end
	
	local skyTemplate = Skys:FindFirstChild(weatherType) -- finds sky template matching weather type
	if skyTemplate then -- checks if template exists
		skyTemplate:Clone().Parent = Lighting -- clones template and parents to Lighting
	end
end

-- destroys all rain effects by calling their destroy methods
local function clearRain() -- function to remove all active rain effects
	for player, effect in pairs(rainEffects) do -- loops through dictionary of rain effects
		effect:destroy() -- calls destroy method on RainEffect object
		rainEffects[player] = nil -- removes entry from dictionary
	end
	
	if rainAmbience then -- checks if rain sound exists
		rainAmbience:Stop() -- stops the looping sound
		rainAmbience:Destroy() -- destroys sound instance
		rainAmbience = nil -- clears reference
	end
end

local function createRainForPlayer(player) -- function to create rain for specific player
	if rainEffects[player] then -- checks if rain already exists for this player
		return -- exits early to prevent duplicates
	end
	
	rainEffects[player] = RainEffect.new(player) -- creates new RainEffect and stores in dictionary
end

-- calls updatePosition on each rain effect object
local function updateRainPositions() -- function to update all rain positions
	for player, effect in pairs(rainEffects) do -- loops through dictionary
		if effect then -- checks if effect object exists
			effect:updatePosition() -- calls updatePosition method
		end
	end
end

-- stops the thunder thread and destroys all active lightning strikes
local function stopThunder() -- function to stop thunder weather
	thunderActive = false -- sets flag to false to stop thunder cycle loop
	
	if thunderThread then -- checks if thread exists
		task.cancel(thunderThread) -- cancels the running thread
		thunderThread = nil -- clears reference
	end
	
	for _, strike in ipairs(activeStrikes) do -- loops through all active strikes
		if strike and strike.active then -- checks if strike exists and is active
			strike:destroy() -- calls destroy method on strike
		end
	end
	
	activeStrikes = {} -- clears the array
end

-- spawns a lightning strike at a random position around the player
-- uses polar coordinates via CFrame rotation for circular distribution
local function spawnLightningNearPlayer(player) -- function to spawn lightning near specific player
	local character = player.Character -- gets player's character
	if not character then -- checks if character exists
		return -- exits if no character
	end
	
	local hrp = character:FindFirstChild("HumanoidRootPart") -- gets HumanoidRootPart
	if not hrp then -- checks if HumanoidRootPart exists
		return -- exits if no HumanoidRootPart
	end
	
	-- convert polar coordinates to cartesian using CFrame rotation
	local angle = math.random() * math.pi * 2 -- generates random angle between 0 and 2π
	local distance = math.random() * LIGHTNING_SPAWN_RADIUS -- generates random distance within radius
	local offsetCFrame = CFrame.new(hrp.Position) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, -distance) -- rotates then offsets
	local spawnPos = offsetCFrame.Position + Vector3.new(0, math.random(LIGHTNING_HEIGHT_MIN, LIGHTNING_HEIGHT_MAX), 0) -- adds random height
	
	local strike = LightningStrike.new(spawnPos) -- creates new lightning strike at calculated position
	table.insert(activeStrikes, strike) -- adds strike to active strikes array
end

-- loop that periodically spawns multiple lightning strikes
-- runs in a separate thread until thunderActive becomes false
local function thunderCycle() -- function that runs the thunder loop
	while thunderActive do -- loops while flag is true
		local players = Players:GetPlayers() -- gets array of all players
		
		if #players > 0 then -- checks if there are any players in game
			local strikeCount = math.min(#players, math.random(LIGHTNING_MIN_STRIKES, LIGHTNING_MAX_STRIKES)) -- picks random strike count
			local usedIndices = {} -- table to track which player indices we've used
			
			-- spawn strikes at different random players
			for _ = 1, strikeCount do -- loops for number of strikes
				local idx -- declares index variable
				repeat -- starts repeat-until loop
					idx = math.random(1, #players) -- generates random player index
				until not usedIndices[idx] -- repeats until we get unused index
				usedIndices[idx] = true -- marks this index as used
				
				spawnLightningNearPlayer(players[idx]) -- spawns lightning at selected player
			end
		end
		
		task.wait(math.random(THUNDER_DELAY_MIN, THUNDER_DELAY_MAX)) -- waits random time before next cycle
	end
end

local function startThunder() -- function to start thunder cycle
	if thunderActive then -- checks if thunder is already active
		return -- exits to prevent multiple cycles
	end
	
	thunderActive = true -- sets flag to true
	thunderThread = task.spawn(thunderCycle) -- spawns new thread running thunderCycle function
end

local function clearSounds() -- function to remove all sounds from workspace
	for _, child in ipairs(Workspace:GetChildren()) do -- loops through all children of Workspace
		if child:IsA("Sound") then -- checks if child is a Sound instance
			child:Stop() -- stops sound playback
			child:Destroy() -- destroys sound instance
		end
	end
end

-- applies a weather type by coordinating sky, rain, thunder, and audio systems
local function applyWeather(weatherType) -- function to apply a specific weather
	if weatherType == currentWeather then -- checks if weather is already active
		return -- exits early if no change needed
	end
	
	setSky(weatherType) -- changes the sky
	clearSounds() -- removes old sounds
	stopThunder() -- stops thunder if active
	clearRain() -- removes rain effects
	
	if weatherType == "Clear" then -- checks if weather is Clear
		currentWeather = "Clear" -- updates current weather variable
		
	elseif weatherType == "Rain" then -- checks if weather is Rain
		for _, player in ipairs(Players:GetPlayers()) do -- loops through all players
			createRainForPlayer(player) -- creates rain for each player
		end
		
		rainAmbience = rainSoundTemplate:Clone() -- clones rain sound template
		rainAmbience.Parent = Workspace -- parents to Workspace
		rainAmbience.Looped = true -- sets sound to loop
		rainAmbience.Volume = 1 -- sets volume to maximum
		rainAmbience:Play() -- starts playing sound
		
		currentWeather = "Rain" -- updates current weather
		
	elseif weatherType == "Thunder" then -- checks if weather is Thunder
		for _, player in ipairs(Players:GetPlayers()) do -- loops through all players
			createRainForPlayer(player) -- creates rain for each player
		end
		
		rainAmbience = rainSoundTemplate:Clone() -- clones rain sound
		rainAmbience.Parent = Workspace -- parents to Workspace
		rainAmbience.Looped = true -- enables looping
		rainAmbience.Volume = 1 -- sets full volume
		rainAmbience:Play() -- starts playback
		
		startThunder() -- starts the thunder cycle
		currentWeather = "Thunder" -- updates current weather
	end
end

-- selects a weather type using weighted randomization
local function chooseWeather() -- function to randomly pick weather based on weights
	local totalWeight = 0 -- initializes sum variable
	for _, weight in pairs(weatherWeights) do -- loops through all weight values
		totalWeight += weight -- adds each weight to total
	end
	
	local roll = math.random() * totalWeight -- generates random number between 0 and total weight
	local cumulative = 0 -- initializes accumulator variable
	
	-- accumulate weights until the roll falls within a weather's range
	for _, weatherType in ipairs(weatherTypes) do -- loops through weather types array
		cumulative += weatherWeights[weatherType] -- adds this weather's weight to cumulative sum
		if roll <= cumulative then -- checks if random roll is within this weather's range
			return weatherType -- returns this weather type
		end
	end
	
	return weatherTypes[#weatherTypes] -- fallback returns last weather type
end

--// Event handlers

-- creates rain for newly joined players if weather requires it
Players.PlayerAdded:Connect(function(player) -- connects to PlayerAdded event
	if currentWeather == "Rain" or currentWeather == "Thunder" then -- checks if current weather includes rain
		createRainForPlayer(player) -- creates rain for new player
	end
end)

-- cleans up rain effects when a player leaves
Players.PlayerRemoving:Connect(function(player) -- connects to PlayerRemoving event
	if rainEffects[player] then -- checks if this player has rain effect
		rainEffects[player]:destroy() -- destroys the rain effect
		rainEffects[player] = nil -- removes from dictionary
	end
end)

--// Main loop

while true do -- infinite loop for weather cycling
	local weather = chooseWeather() -- picks random weather based on weights
	
	-- keep rerolling until we get a different weather than current
	while weather == currentWeather do -- loops while same weather is selected
		weather = chooseWeather() -- picks new weather
	end
	
	applyWeather(weather) -- applies the selected weather
	
	-- weather persists for a random duration
	local duration = math.random(WEATHER_DURATION_MIN, WEATHER_DURATION_MAX) -- picks random duration
	for _ = 1, duration do -- loops for duration in seconds
		updateRainPositions() -- updates rain positions to follow players
		task.wait(1) -- waits 1 second
	end
end
