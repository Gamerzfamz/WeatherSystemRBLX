--// Services
-- using WaitForChild makes sure everything loads before we try to use it
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

--// Asset references
-- keeping assets organized in folders makes it easier to add new weather types later
local Assets = ReplicatedStorage:WaitForChild("WeatherAssets")
local Skys = Assets:WaitForChild("Skys")
local Sounds = Assets:WaitForChild("Sounds")
local VFX = Assets:WaitForChild("VFX")

--// Effect templates
-- storing these at the top so we don't have to find them every time
local rainTemplate = VFX:WaitForChild("Rain")
local lightningTemplate = VFX:WaitForChild("Lightning")

--// Sound templates
-- lightning sound is the initial crack, thunder is the rumble after
local lightningSoundTemplate = Sounds:WaitForChild("Thunder")
local thunderSoundTemplate = Sounds:WaitForChild("Thunder")
local rainSoundTemplate = Sounds:WaitForChild("Rain")

--// Weather configuration
-- the array keeps them in order, the weights table controls how often each appears
local weatherTypes = {"Clear", "Rain", "Thunder"}
local weatherWeights = {
	Clear = 5,    -- most common weather (5 out of 9 times)
	Rain = 2,     -- happens 2 out of 9 times
	Thunder = 2,  -- same rarity as rain
}

--// Configuration constants
-- pulled out all the magic numbers so they're easier to tweak
local RAIN_HEIGHT_OFFSET = 40           -- how high above the player the rain spawns
local LIGHTNING_MIN_FORKS = 3           -- minimum number of lightning strikes per cycle
local LIGHTNING_MAX_FORKS = 7           -- maximum strikes per cycle
local LIGHTNING_FORK_DEPTH = 6          -- how many times the lightning can branch
local LIGHTNING_SEGMENT_LENGTH = 4      -- length of each piece of the lightning bolt
local LIGHTNING_SPAWN_MIN = -20         -- minimum horizontal distance from player
local LIGHTNING_SPAWN_MAX = 20          -- maximum horizontal distance
local LIGHTNING_HEIGHT_MIN = 10         -- minimum height above player
local LIGHTNING_HEIGHT_MAX = 20         -- maximum height
local THUNDER_DELAY_MIN = 10            -- shortest wait between thunder cycles
local THUNDER_DELAY_MAX = 20            -- longest wait between thunder cycles
local LIGHTNING_DURATION = 4            -- how long the lightning visual stays before cleanup
local SOUND_ROLLOFF_DISTANCE = 100      -- how far away sounds start getting quieter
local THUNDER_ROLLOFF_DISTANCE = 150    -- thunder carries further than lightning
local RAIN_MUTE_RADIUS = 50             -- how close to lightning before rain gets muted
local WEATHER_DURATION_MIN = 60         -- shortest time a weather lasts
local WEATHER_DURATION_MAX = 180        -- longest time a weather lasts

--// Internal state management
-- tracking current state instead of checking if objects exist - faster this way
local lastWeather = nil                 -- what weather is currently active
local rainParts = {}                    -- table connecting each player to their rain part
local thunderRunning = false            -- stops multiple thunder loops from starting
local thunderTask = nil                 -- keeps track of the thunder task so we can cancel it
local lightningParts = {}               -- all the lightning segments that need cleanup
local rainSoundInstance = nil           -- the single rain sound that loops

-- replaces the skybox with a new one for the current weather
-- destroys the old one completely instead of just deparenting it
local function setSky(name)
	local oldSky = Lighting:FindFirstChildOfClass("Sky")
	if oldSky then 
		oldSky:Destroy() 
	end

	-- cloning preserves the original in ReplicatedStorage
	local sky = Skys:FindFirstChild(name)
	if sky then
		sky:Clone().Parent = Lighting
	end
end

-- cleans up all rain effects and stops the rain sound
local function clearRain()
	-- go through each player's rain part and destroy it
	for player, part in pairs(rainParts) do
		part:Destroy()
		rainParts[player] = nil  -- setting to nil helps with garbage collection
	end

	-- stop the rain sound if it's playing
	if rainSoundInstance then
		rainSoundInstance:Stop()      -- stopping before destroying prevents weird audio glitches
		rainSoundInstance:Destroy()
		rainSoundInstance = nil
	end
end

-- creates a rain effect that follows a specific player
-- each player gets their own rain part so it can follow them individually
local function createRainForPlayer(player)
	-- don't create duplicates
	if rainParts[player] then 
		return 
	end

	local part = rainTemplate:Clone()
	part.Anchored = true          -- anchored so it doesn't fall
	part.CanCollide = false       -- non-collidable so players can walk through it
	part.Parent = Workspace       

	rainParts[player] = part
end

-- moves all the rain parts to stay above their players
-- runs every second to keep rain following players as they move
local function updateRainPositions()
	for player, part in pairs(rainParts) do
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")

		if hrp then
			-- CFrame.new is more efficient than setting Position directly
			part.CFrame = CFrame.new(hrp.Position + Vector3.new(0, RAIN_HEIGHT_OFFSET, 0))
		else
			-- if player doesn't have a character, move rain way up so it's not visible
			part.CFrame = CFrame.new(0, 1000, 0)
		end
	end
end

-- stops the thunder cycle and destroys all lightning visuals
local function stopThunder()
	thunderRunning = false

	-- cancel the running task if there is one
	if thunderTask then
		thunderTask:Cancel()
		thunderTask = nil
	end

	-- destroy all lightning parts
	for _, part in pairs(lightningParts) do
		if part and part.Parent then
			part:Destroy()
		end
	end

	lightningParts = {}
end

-- adjusts sound volume based on how far the nearest player is
-- uses linear falloff so sounds get quieter with distance
local function updateSoundVolumes(sounds, position)
	local players = Players:GetPlayers()

	for _, sound in pairs(sounds) do
		local closestDist = math.huge  -- start with a really big number

		-- find the closest player to the sound
		for _, player in pairs(players) do
			local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if hrp then
				local dist = (hrp.Position - position).Magnitude
				if dist < closestDist then
					closestDist = dist
				end
			end
		end

		-- calculate volume - gets quieter as distance increases
		-- math.clamp keeps it between 0 and 1
		local volume = math.clamp(1 - closestDist / SOUND_ROLLOFF_DISTANCE, 0, 1)
		sound.Volume = volume
	end
end

-- mutes the rain sound when players are near lightning strikes
-- this simulates how loud thunder would drown out the rain sound
local function updateRainSoundVolume(mutePosition, muteRadius)
	if not rainSoundInstance then 
		return 
	end

	local mute = false

	-- check if any player is close to the lightning
	for _, player in pairs(Players:GetPlayers()) do
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if hrp and (hrp.Position - mutePosition).Magnitude <= muteRadius then
			mute = true
			break  -- found one, no need to keep checking
		end
	end

	-- either full volume or silent, no in-between
	rainSoundInstance.Volume = mute and 0 or 1
end

-- creates one segment of the lightning bolt between two points
local function createLightningSegment(startPos, endPos)
	local segment = Instance.new("Part")

	-- size the segment to fit between the two points
	local length = (endPos - startPos).Magnitude
	segment.Size = Vector3.new(0.2, length, 0.2)

	segment.Anchored = true
	segment.CanCollide = false
	segment.Material = Enum.Material.Neon    -- neon gives it that bright glowing look
	segment.Color = Color3.fromRGB(255, 255, 255)
	segment.Transparency = 0.25              -- slight transparency looks more realistic

	-- position the segment between start and end
	-- CFrame.new(pos1, pos2) makes it point from pos1 toward pos2
	-- then offset by half the length to center it
	local cframe = CFrame.new(startPos, endPos) * CFrame.new(0, length / 2, 0)
	segment.CFrame = cframe

	segment.Parent = Workspace
	table.insert(lightningParts, segment)

	return segment
end

-- generates a random direction for lightning to branch
-- biased downward to make lightning go toward the ground
local function getRandomLightningDirection()
	local x = math.random() - 0.5
	local z = math.random() - 0.5
	local y = -0.5 - math.random() * 0.3  -- always going down

	return Vector3.new(x, y, z).Unit  -- normalize so all segments are same length
end

-- recursively builds a branching lightning bolt
-- this is where the lightning gets its realistic forked appearance
local function generateLightningFork(position, direction, depth, maxDepth)
	-- stop when we've branched too many times
	if depth > maxDepth then 
		return 
	end

	-- calculate where this segment ends
	local offset = direction.Unit * LIGHTNING_SEGMENT_LENGTH
	local newPos = position + offset

	-- create the visual segment
	createLightningSegment(position, newPos)

	-- 70% chance to continue the main branch
	-- higher chance means the lightning has a main "trunk"
	if math.random() < 0.7 then
		local newDirection = getRandomLightningDirection()
		generateLightningFork(newPos, newDirection, depth + 1, maxDepth)
	end

	-- 50% chance to create a side branch
	-- lower chance keeps it from getting too bushy
	if math.random() < 0.5 then
		local forkDirection = getRandomLightningDirection()
		generateLightningFork(newPos, forkDirection, depth + 1, maxDepth)
	end
end

-- starts a complete lightning bolt from a position in the sky
local function createForkingLightning(startPos)
	local initialDirection = Vector3.new(0, -1, 0)  -- straight down
	generateLightningFork(startPos, initialDirection, 1, LIGHTNING_FORK_DEPTH)
end

-- spawns lightning and thunder near a player
-- uses 3D positional audio so it sounds like it's coming from the right direction
local function spawnLightningNearPlayer(player)
	local character = player.Character
	if not character then 
		return 
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then 
		return 
	end

	-- randomize where the lightning appears relative to the player
	-- this keeps it from being predictable
	local offsetX = math.random(LIGHTNING_SPAWN_MIN, LIGHTNING_SPAWN_MAX)
	local offsetZ = math.random(LIGHTNING_SPAWN_MIN, LIGHTNING_SPAWN_MAX)
	local offsetY = math.random(LIGHTNING_HEIGHT_MIN, LIGHTNING_HEIGHT_MAX)
	local spawnPos = hrp.Position + Vector3.new(offsetX, offsetY, offsetZ)

	-- store the current parts count before creating this strike
	-- this way each strike only cleans up its own parts
	local startIndex = #lightningParts

	-- create the visual lightning bolt
	createForkingLightning(spawnPos)

	-- store only THIS strike's parts in a separate table
	local thisStrikeParts = {}
	for i = startIndex + 1, #lightningParts do
		table.insert(thisStrikeParts, lightningParts[i])
	end

	-- create the lightning crack sound at the strike location
	local lightningSound = lightningSoundTemplate:Clone()
	lightningSound.Parent = Workspace
	lightningSound.Position = spawnPos
	lightningSound.RollOffMode = Enum.RollOffMode.Linear
	lightningSound.MaxDistance = SOUND_ROLLOFF_DISTANCE
	lightningSound:Play()

	-- create the thunder rumble sound
	local thunderSound = thunderSoundTemplate:Clone()
	thunderSound.Parent = Workspace
	thunderSound.Position = spawnPos
	thunderSound.RollOffMode = Enum.RollOffMode.Linear
	thunderSound.MaxDistance = THUNDER_ROLLOFF_DISTANCE  -- thunder travels further
	thunderSound:Play()

	-- this loop handles cleanup and volume updates
	local connection
	local startTime = tick()

	-- heartbeat runs every frame for smooth volume changes
	connection = RunService.Heartbeat:Connect(function()
		if tick() - startTime > LIGHTNING_DURATION then
			-- time's up, clean up only THIS strike's parts
			for _, part in pairs(thisStrikeParts) do
				if part and part.Parent then
					part:Destroy()
				end
			end
			connection:Disconnect()
		else
			-- still active, keep updating volumes based on player distance
			updateSoundVolumes({lightningSound, thunderSound}, spawnPos)
			updateRainSoundVolume(spawnPos, RAIN_MUTE_RADIUS)
		end
	end)
end

-- the main thunder loop that keeps spawning lightning
-- runs in its own thread while thunder weather is active
local function thunderCycle()
	while thunderRunning do
		local players = Players:GetPlayers()

		-- only spawn lightning if there are players in the game
		if #players > 0 then
			local used = {}  -- tracks which players we've already used

			-- spawn between 3-7 lightning strikes, but not more than number of players
			local strikes = math.min(#players, math.random(LIGHTNING_MIN_FORKS, LIGHTNING_MAX_FORKS))

			-- spawn lightning at different players
			for _ = 1, strikes do
				-- pick a random player we haven't used yet
				local idx
				repeat 
					idx = math.random(1, #players) 
				until not used[idx]
				used[idx] = true

				spawnLightningNearPlayer(players[idx])
			end
		end

		-- wait a random amount of time before the next round of lightning
		-- randomness makes it feel more natural
		task.wait(math.random(THUNDER_DELAY_MIN, THUNDER_DELAY_MAX))
	end
end

-- starts the thunder cycle in a separate thread
local function startThunder()
	-- don't start multiple thunder loops
	if thunderRunning then 
		return 
	end

	thunderRunning = true
	-- task.spawn creates a new thread without blocking this one
	thunderTask = task.spawn(thunderCycle)
end

-- removes all sounds from workspace
-- used when switching weather to prevent sounds from overlapping
local function clearSounds()
	for _, sound in pairs(Workspace:GetChildren()) do
		if sound:IsA("Sound") then
			sound:Stop()      -- stop it first to avoid weird audio artifacts
			sound:Destroy()
		end
	end
end

-- applies a weather type and handles the transition from previous weather
-- this is the main function that coordinates all the weather systems
local function applyWeather(weather)
	-- don't do anything if we're already on this weather
	if weather == lastWeather then 
		return 
	end

	-- change the skybox first so it's immediately visible
	setSky(weather)

	-- clean up the old weather
	clearSounds()
	stopThunder()
	clearRain()

	-- set up the new weather
	if weather == "Clear" then
		-- clear weather doesn't need any special setup
		lastWeather = "Clear"

	elseif weather == "Rain" then
		-- create rain for everyone who's currently in the game
		for _, player in pairs(Players:GetPlayers()) do
			createRainForPlayer(player)
		end

		-- create the rain ambience sound
		rainSoundInstance = rainSoundTemplate:Clone()
		rainSoundInstance.Parent = Workspace
		rainSoundInstance.Looped = true   -- needs to loop continuously
		rainSoundInstance.Volume = 1
		rainSoundInstance:Play()

		lastWeather = "Rain"

	elseif weather == "Thunder" then
		-- thunder has rain plus the lightning effects
		for _, player in pairs(Players:GetPlayers()) do
			createRainForPlayer(player)
		end

		-- same rain sound as regular rain weather
		rainSoundInstance = rainSoundTemplate:Clone()
		rainSoundInstance.Parent = Workspace
		rainSoundInstance.Looped = true
		rainSoundInstance.Volume = 1
		rainSoundInstance:Play()

		-- start the thunder cycle
		startThunder()

		lastWeather = "Thunder"
	end
end

-- picks a random weather type using the weights we defined earlier
-- higher weight = more likely to be picked
local function chooseWeather()
	-- add up all the weights
	local totalWeight = 0
	for _, w in pairs(weatherWeights) do 
		totalWeight += w 
	end

	-- pick a random number in that range
	local pick = math.random() * totalWeight
	local cumulative = 0

	-- figure out which weather we landed on
	-- works like spinning a weighted wheel
	for _, weather in pairs(weatherTypes) do
		cumulative += weatherWeights[weather]
		if pick <= cumulative then
			return weather
		end
	end

	-- fallback just in case (shouldn't ever get here)
	return weatherTypes[#weatherTypes]
end

--// Event Handlers
-- these make sure new/leaving players get the right weather effects

-- when a player joins, give them rain if the weather calls for it
Players.PlayerAdded:Connect(function(player)
	if lastWeather == "Rain" or lastWeather == "Thunder" then
		createRainForPlayer(player)
	end
end)

-- when a player leaves, clean up their rain part
Players.PlayerRemoving:Connect(function(player)
	if rainParts[player] then
		rainParts[player]:Destroy()
		rainParts[player] = nil
	end
end)

--// Main Weather Loop
-- this runs forever and manages the weather cycles

while true do
	-- pick a new weather
	local weather = chooseWeather()

	-- keep picking until we get something different from current weather
	while weather == lastWeather do
		weather = chooseWeather()
	end

	-- apply the new weather
	applyWeather(weather)

	-- let this weather run for a random duration
	-- updates rain positions every second so rain follows players smoothly
	for _ = 1, math.random(WEATHER_DURATION_MIN, WEATHER_DURATION_MAX) do
		updateRainPositions()
		task.wait(1)
	end
end
