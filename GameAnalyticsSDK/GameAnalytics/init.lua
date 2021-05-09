local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalizationService = game:GetService("LocalizationService")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")
local ScriptContext = game:GetService("ScriptContext")

local Events = require(script.Events)
local GAErrorSeverity = require(script.GAErrorSeverity)
local GAProgressionStatus = require(script.GAProgressionStatus)
local GAResourceFlowType = require(script.GAResourceFlowType)
local Logger = require(script.Logger)
local MarketplacePromise = require(script.Promises.MarketplacePromise)
local Postie = require(ReplicatedStorage.Postie)
local Promise = require(script.Vendor.Promise)
local Scheduler = require(script.Scheduler)
local State = require(script.State)
local Store = require(script.Store)
local Threading = require(script.Threading)
local Utilities = require(script.Utilities)
local Validation = require(script.Validation)
local catchFactory = require(script.Promises.catchFactory)

local GameAnalytics = {
	EGAResourceFlowType = GAResourceFlowType,
	EGAProgressionStatus = GAProgressionStatus,
	EGAErrorSeverity = GAErrorSeverity,
}

-- more detailed types
export type GAResourceFlowType = typeof(GAResourceFlowType.Source)
export type GAProgressionStatus = typeof(GAProgressionStatus.Start)
export type GAErrorSeverity = typeof(GAErrorSeverity.debug)

type Array<Value> = {Value}
type integer = number
type float = number

export type BusinessEventOptions = {
	amount: integer?,
	cartType: string?,
	gamepassId: integer?,
	itemId: string?,
	itemType: string?,
}

export type ResourceEventOptions = {
	amount: float?,
	currency: string?,
	flowType: EGAResourceFlowType?,
	itemId: string?,
	itemType: string?,
}

export type ProgressionEventOptions = {
	progression01: string?,
	progression02: string?,
	progression03: string?,
	progressionStatus: EGAProgressionStatus?,
	score: integer?,
}

export type DesignEventOptions = {
	eventId: string?,
	value: float?,
}

export type ErrorEventOptions = {
	severity: EGAErrorSeverity?,
	message: string?,
}

export type RemoteConfigsValueOptions = {
	defaultValue: any?,
	key: string?,
}

export type InitializeOptions = {
	gameKey: string,
	secretKey: string,

	automaticSendBusinessEvents: boolean?,
	availableCustomDimensions01: Array<string>?,
	availableCustomDimensions02: Array<string>?,
	availableCustomDimensions03: Array<string>?,
	availableGamepasses: Array<integer>?,
	availableResourceCurrencies: Array<string>?,
	availableResourceItemTypes: Array<string>?,
	build: string?,
	enableDebugLog: boolean?,
	enableInfoLog: boolean?,
	enableVerboseLog: boolean?,
	reportErrors: boolean?,
	useCustomUserId: boolean?,
}

local ONE_HOUR_IN_SECONDS = 3600
local MAX_ERRORS_PER_HOUR = 10

local onPlayerReadyEvent
local errorDataStore = {}
local errorCountCache = {}
local errorCountCacheKeys = {}

local initializationQueue = {}
local initializationQueueByUserId = {}

local Scheduler_Spawn = Scheduler.Spawn
local Scheduler_Wait = Scheduler.Wait

local function getCountryRegionForPlayerAsync(player: Player)
	return LocalizationService:GetCountryRegionForPlayerAsync(player)
end

local function promiseCountryRegionForPlayer(player: Player)
	return Promise.defer(function(resolve, reject)
		local success, countryRegionOrError = pcall(getCountryRegionForPlayerAsync, player);
		(success and resolve or reject)(countryRegionOrError)
	end)
end

local function addToInitializationQueue(func, ...)
	if initializationQueue ~= nil then
		table.insert(initializationQueue, {
			Args = table.pack(...),
			Func = func,
		})

		Logger:information("Added event to initialization queue")
	else
		--This should never happen
		Logger:warning("Initialization queue already cleared.")
	end
end

local function addToInitializationQueueByUserId(userId, func, ...)
	if not GameAnalytics:isPlayerReady(userId) then
		if initializationQueueByUserId[userId] == nil then
			initializationQueueByUserId[userId] = {}
		end

		table.insert(initializationQueueByUserId[userId], {
			Args = table.pack(...),
			Func = func,
		})

		Logger:information("Added event to player initialization queue")
	else
		--This should never happen
		Logger:warning("Player initialization queue already cleared.")
	end
end

-- local functions
local function isSdkReady(options)
	local playerId = options.playerId or nil
	local needsInitialized = options.needsInitialized or true
	local shouldWarn = options.shouldWarn or false
	local message = options.message or ""

	-- Is SDK initialized
	if needsInitialized and not State.Initialized then
		if shouldWarn then
			Logger:warning(message .. " SDK is not initialized")
		end

		return false
	end

	-- Is SDK enabled
	if needsInitialized and playerId and not State:isEnabled(playerId) then
		if shouldWarn then
			Logger:warning(message .. " SDK is disabled")
		end

		return false
	end

	-- Is session started
	if needsInitialized and playerId and not State:sessionIsStarted(playerId) then
		if shouldWarn then
			Logger:warning(message .. " Session has not started yet")
		end

		return false
	end

	return true
end

function GameAnalytics:configureAvailableCustomDimensions01(customDimensions: Array<string>)
	if isSdkReady({needsInitialized = true, shouldWarn = false}) then
		Logger:warning("Available custom dimensions must be set before SDK is initialized")
		return
	end

	State:setAvailableCustomDimensions01(customDimensions)
end

function GameAnalytics:configureAvailableCustomDimensions02(customDimensions: Array<string>)
	if isSdkReady({needsInitialized = true, shouldWarn = false}) then
		Logger:warning("Available custom dimensions must be set before SDK is initialized")
		return
	end

	State:setAvailableCustomDimensions02(customDimensions)
end

function GameAnalytics:configureAvailableCustomDimensions03(customDimensions: Array<string>)
	if isSdkReady({needsInitialized = true, shouldWarn = false}) then
		Logger:warning("Available custom dimensions must be set before SDK is initialized")
		return
	end

	State:setAvailableCustomDimensions03(customDimensions)
end

function GameAnalytics:configureAvailableResourceCurrencies(resourceCurrencies: Array<string>)
	if isSdkReady({needsInitialized = true, shouldWarn = false}) then
		Logger:warning("Available resource currencies must be set before SDK is initialized")
		return
	end

	Events:setAvailableResourceCurrencies(resourceCurrencies)
end

function GameAnalytics:configureAvailableResourceItemTypes(resourceItemTypes: Array<string>)
	if isSdkReady({needsInitialized = true, shouldWarn = false}) then
		Logger:warning("Available resource item types must be set before SDK is initialized")
		return
	end

	Events:setAvailableResourceItemTypes(resourceItemTypes)
end

function GameAnalytics:configureBuild(build: string)
	if isSdkReady({needsInitialized = true, shouldWarn = false}) then
		Logger:warning("Build version must be set before SDK is initialized.")
		return
	end

	Events:setBuild(build)
end

function GameAnalytics:configureAvailableGamepasses(availableGamepasses: Array<integer>)
	if isSdkReady({needsInitialized = true, shouldWarn = false}) then
		Logger:warning("Available gamepasses must be set before SDK is initialized.")
		return
	end

	State:setAvailableGamepasses(availableGamepasses)
end

function GameAnalytics:startNewSession(player: Player, gameAnalyticsData)
	Threading:performTaskOnGAThread(function()
		if not State:isEventSubmissionEnabled() then
			return
		end

		if not State.Initialized then
			Logger:warning("Cannot start new session. SDK is not initialized yet.")
			return
		end

		State:startNewSession(player, gameAnalyticsData)
	end)
end

function GameAnalytics:endSession(playerId: integer)
	Threading:performTaskOnGAThread(function()
		if not State:isEventSubmissionEnabled() then
			return
		end

		State:endSession(playerId)
	end)
end

function GameAnalytics:filterForBusinessEvent(text: string)
	return string.gsub(text, "[^A-Za-z0-9%s%-_%.%(%)!%?]", "")
end

function GameAnalytics:addBusinessEvent(playerId: integer, options: BusinessEventOptions)
	Threading:performTaskOnGAThread(function()
		if not State:isEventSubmissionEnabled() then
			return
		end

		if not isSdkReady({playerId = playerId, needsInitialized = true, shouldWarn = false, message = "Could not add business event"}) then
			if playerId then
				addToInitializationQueueByUserId(playerId, self.addBusinessEvent, self, playerId, options)
			else
				addToInitializationQueue(self.addBusinessEvent, self, playerId, options)
			end

			return
		end

		-- Send to events
		local amount = options.amount or 0
		local itemType = options.itemType or ""
		local itemId = options.itemId or ""
		local cartType = options.cartType or ""
		local USDSpent = math.floor((amount * 0.7) * 0.35)
		local gamepassId = options.gamepassId or nil

		Events:addBusinessEvent(playerId, "USD", USDSpent, itemType, itemId, cartType)

		if itemType == "Gamepass" and cartType ~= "Website" then
			local player = Players:GetPlayerByUserId(playerId)
			if player then
				local playerData = Store.GetPlayerData(player)
				if not playerData.OwnedGamepasses then
					playerData.OwnedGamepasses = {}
				end

				table.insert(playerData.OwnedGamepasses, gamepassId)
				Store.PlayerCache[playerId] = playerData
				Store.SavePlayerData(player)
			end
		end
	end)
end

function GameAnalytics:addResourceEvent(playerId: integer, options: ResourceEventOptions)
	Threading:performTaskOnGAThread(function()
		if not State:isEventSubmissionEnabled() then
			return
		end

		if not isSdkReady({playerId = playerId, needsInitialized = true, shouldWarn = false, message = "Could not add resource event"}) then
			if playerId then
				addToInitializationQueueByUserId(playerId, self.addResourceEvent, self, playerId, options)
			else
				addToInitializationQueue(self.addResourceEvent, self, playerId, options)
			end

			return
		end

		-- Send to events
		local flowType = options.flowType or 0
		local currency = options.currency or ""
		local amount = options.amount or 0
		local itemType = options.itemType or ""
		local itemId = options.itemId or ""

		Events:addResourceEvent(playerId, flowType, currency, amount, itemType, itemId)
	end)
end

function GameAnalytics:addProgressionEvent(playerId: integer, options: ProgressionEventOptions)
	Threading:performTaskOnGAThread(function()
		if not State:isEventSubmissionEnabled() then
			return
		end

		if not isSdkReady({playerId = playerId, needsInitialized = true, shouldWarn = false, message = "Could not add progression event"}) then
			if playerId then
				addToInitializationQueueByUserId(playerId, self.addProgressionEvent, self, playerId, options)
			else
				addToInitializationQueue(self.addProgressionEvent, self, playerId, options)
			end

			return
		end

		-- Send to events
		local progressionStatus = options.progressionStatus or 0
		local progression01 = options.progression01 or ""
		local progression02 = options.progression02 or nil
		local progression03 = options.progression03 or nil
		local score = options.score or nil

		Events:addProgressionEvent(playerId, progressionStatus, progression01, progression02, progression03, score)
	end)
end

function GameAnalytics:addDesignEvent(playerId: integer, options: DesignEventOptions)
	Threading:performTaskOnGAThread(function()
		if not State:isEventSubmissionEnabled() then
			return
		end

		if not isSdkReady({playerId = playerId, needsInitialized = true, shouldWarn = false, message = "Could not add design event"}) then
			if playerId then
				addToInitializationQueueByUserId(playerId, self.addDesignEvent, self, playerId, options)
			else
				addToInitializationQueue(self.addDesignEvent, self, playerId, options)
			end

			return
		end

		-- Send to events
		local eventId = options.eventId or ""
		local value = options.value or nil

		Events:addDesignEvent(playerId, eventId, value)
	end)
end

function GameAnalytics:addErrorEvent(playerId: integer, options: ErrorEventOptions)
	Threading:performTaskOnGAThread(function()
		if not State:isEventSubmissionEnabled() then
			return
		end

		if not isSdkReady({playerId = playerId, needsInitialized = true, shouldWarn = false, message = "Could not add error event"}) then
			if playerId then
				addToInitializationQueueByUserId(playerId, self.addErrorEvent, self, playerId, options)
			else
				addToInitializationQueue(self.addErrorEvent, self, playerId, options)
			end

			return
		end

		-- Send to events
		local severity = options.severity or 0
		local message = options.message or ""

		Events:addErrorEvent(playerId, severity, message)
	end)
end

function GameAnalytics:setEnabledDebugLog(flag: boolean)
	if RunService:IsStudio() then
		if flag then
			Logger:setDebugLog(flag)
			Logger:information("Debug logging enabled")
		else
			Logger:information("Debug logging disabled")
			Logger:setDebugLog(flag)
		end
	else
		Logger:information("setEnabledDebugLog can only be used in studio")
	end
end

function GameAnalytics:setEnabledInfoLog(flag: boolean)
	if flag then
		Logger:setInfoLog(flag)
		Logger:information("Info logging enabled")
	else
		Logger:information("Info logging disabled")
		Logger:setInfoLog(flag)
	end
end

function GameAnalytics:setEnabledVerboseLog(flag: boolean)
	if flag then
		Logger:setVerboseLog(flag)
		Logger:verboseInformation("Verbose logging enabled")
	else
		Logger:verboseInformation("Verbose logging disabled")
		Logger:setVerboseLog(flag)
	end
end

function GameAnalytics:setEnabledEventSubmission(flag: boolean)
	Threading:performTaskOnGAThread(function()
		if flag then
			State:setEventSubmission(flag)
			Logger:information("Event submission enabled")
		else
			Logger:information("Event submission disabled")
			State:setEventSubmission(flag)
		end
	end)
end

function GameAnalytics:setCustomDimension01(playerId: integer, dimension: string)
	Threading:performTaskOnGAThread(function()
		if not Validation.validateDimension(State._availableCustomDimensions01, dimension) then
			Logger:warning("Could not set custom01 dimension value to '" .. dimension .. "'. Value not found in available custom01 dimension values")
			return
		end

		if not isSdkReady({playerId = playerId, needsInitialized = true, shouldWarn = true, message = "Could not set custom01 dimension"}) then
			return
		end

		State:setCustomDimension01(playerId, dimension)
	end)
end

function GameAnalytics:setCustomDimension02(playerId: integer, dimension: string)
	Threading:performTaskOnGAThread(function()
		if not Validation.validateDimension(State._availableCustomDimensions02, dimension) then
			Logger:warning("Could not set custom02 dimension value to '" .. dimension .. "'. Value not found in available custom02 dimension values")
			return
		end

		if not isSdkReady({playerId = playerId, needsInitialized = true, shouldWarn = true, message = "Could not set custom02 dimension"}) then
			return
		end

		State:setCustomDimension02(playerId, dimension)
	end)
end

function GameAnalytics:setCustomDimension03(playerId: integer, dimension: string)
	Threading:performTaskOnGAThread(function()
		if not Validation.validateDimension(State._availableCustomDimensions03, dimension) then
			Logger:warning("Could not set custom03 dimension value to '" .. dimension .. "'. Value not found in available custom03 dimension values")
			return
		end

		if not isSdkReady({playerId = playerId, needsInitialized = true, shouldWarn = true, message = "Could not set custom03 dimension"}) then
			return
		end

		State:setCustomDimension03(playerId, dimension)
	end)
end

function GameAnalytics:setEnabledReportErrors(flag: boolean)
	Threading:performTaskOnGAThread(function()
		State.ReportErrors = flag
	end)
end

function GameAnalytics:setEnabledCustomUserId(flag: boolean)
	Threading:performTaskOnGAThread(function()
		State.UseCustomUserId = flag
	end)
end

function GameAnalytics:setEnabledAutomaticSendBusinessEvents(flag: boolean)
	Threading:performTaskOnGAThread(function()
		State.AutomaticSendBusinessEvents = flag
	end)
end

function GameAnalytics:addGameAnalyticsTeleportData(playerIds: Array<integer>, teleportData: Dictionary<any>)
	local gameAnalyticsTeleportData = {}
	for _, playerId in ipairs(playerIds) do
		local playerData = Store.GetPlayerDataFromCache(playerId)
		playerData.PlayerTeleporting = true
		local data = {
			SessionID = playerData.SessionID,
			Sessions = playerData.Sessions,
			SessionStart = playerData.SessionStart,
		}

		gameAnalyticsTeleportData[tostring(playerId)] = data
	end

	teleportData.gameanalyticsData = gameAnalyticsTeleportData
	return teleportData
end

function GameAnalytics:getRemoteConfigsValueAsString(playerId: integer, options: RemoteConfigsValueOptions)
	local key = options.key or ""
	local defaultValue = options.defaultValue or nil
	return State:getRemoteConfigsStringValue(playerId, key, defaultValue)
end

function GameAnalytics:isRemoteConfigsReady(playerId: integer)
	return State:isRemoteConfigsReady(playerId)
end

function GameAnalytics:getRemoteConfigsContentAsString(playerId: integer)
	return State:getRemoteConfigsContentAsString(playerId)
end

-- EPIC WIN

function GameAnalytics:PlayerJoined(player: Player)
	local joinData = player:GetJoinData()
	local teleportData = joinData.TeleportData
	local gameAnalyticsData = nil

	--Variables
	local playerData = Store.GetPlayerData(player)

	if teleportData then
		gameAnalyticsData = teleportData.gameanalyticsData and teleportData.gameanalyticsData[tostring(player.UserId)]
	end

	local cachedPlayerData = Store.GetPlayerDataFromCache(player.UserId)
	if cachedPlayerData then
		if gameAnalyticsData then
			cachedPlayerData.SessionID = gameAnalyticsData.SessionID
			cachedPlayerData.SessionStart = gameAnalyticsData.SessionStart
		end

		cachedPlayerData.PlayerTeleporting = false
		return
	end

	local playerPlatform = "unknown"
	local isSuccessful, platform = Postie.InvokeClient("getPlatform", player, 5)
	if isSuccessful then
		playerPlatform = platform
	end

	--Fill Data
	for key, value in pairs(Store.BasePlayerData) do
		playerData[key] = playerData[key] or value
	end

	promiseCountryRegionForPlayer(player):andThen(function(countryCode)
		playerData.CountryCode = countryCode
	end):catch(function(countryCodeError)
		warn("Failure in function promiseCountryRegionForPlayer:", tostring(countryCodeError))
		Events:addSdkErrorEvent(player.UserId, "event_validation", "player_joined", "string_empty_or_null", "country_code", "")
	end):await()

	Store.PlayerCache[player.UserId] = playerData

	playerData.Platform = (playerPlatform == "Console" and "uwp_console") or (playerPlatform == "Mobile" and "uwp_mobile") or (playerPlatform == "Desktop" and "uwp_desktop") or "uwp_desktop"
	playerData.OS = playerData.Platform .. " 0.0.0"

	local playerCustomUserId = ""
	if State.UseCustomUserId then
		local success, customUserId = Postie.InvokeClient("getCustomUserId", player, 5)
		if success then
			playerCustomUserId = customUserId
		end
	end

	if not Utilities.isStringNullOrEmpty(playerCustomUserId) then
		Logger:information("Using custom id: " .. playerCustomUserId)
		playerData.CustomUserId = playerCustomUserId
	end

	self:startNewSession(player, gameAnalyticsData)

	onPlayerReadyEvent = onPlayerReadyEvent or ReplicatedStorage:WaitForChild("OnPlayerReadyEvent")
	onPlayerReadyEvent:Fire(player)

	-- Validate
	if State.AutomaticSendBusinessEvents then
		-- Website gamepasses
		if playerData.OwnedGamepasses == nil then -- player is new (or is playing after SDK update)
			local ownedGamepasses = {}
			local length = 0
			local availableGamepasses = State._availableGamepasses
			local userId = player.UserId

			playerData.OwnedGamepasses = ownedGamepasses

			local promises = table.create(#availableGamepasses)
			for index, gamePassId in ipairs(availableGamepasses) do
				promises[index] = MarketplacePromise.promiseUserOwnsGamePass(userId, gamePassId)
			end

			Promise.all(promises):andThen(function(results)
				for index, result in ipairs(results) do
					if result then
						length += 1
						ownedGamepasses[length] = availableGamepasses[index]
					end
				end
			end):catch(catchFactory("Promise.all")):await()

			-- Player's data is now up to date. gamepass purchases on website can now be tracked in future visits
			Store.PlayerCache[player.UserId] = playerData
			Store.SavePlayerData(player)
		else
			-- build a list of the game passes a user owns
			local currentlyOwned = {}
			local length = 0
			local availableGamepasses = State._availableGamepasses
			local userId = player.UserId

			local promises = table.create(#availableGamepasses)
			for index, gamePassId in ipairs(availableGamepasses) do
				promises[index] = MarketplacePromise.promiseUserOwnsGamePass(userId, gamePassId)
			end

			Promise.all(promises):andThen(function(results)
				for index, result in ipairs(results) do
					if result then
						length += 1
						currentlyOwned[length] = availableGamepasses[index]
					end
				end
			end):catch(catchFactory("Promise.all")):await()

			-- make a table so it's easier to compare to stored game passes
			local storedGamepassesTable = {}
			for _, id in ipairs(playerData.OwnedGamepasses) do
				storedGamepassesTable[id] = true
			end

			-- compare stored game passes to currently owned game passses
			for _, id in ipairs(currentlyOwned) do
				if not storedGamepassesTable[id] then
					table.insert(playerData.OwnedGamepasses, id)

					MarketplacePromise.promiseProductInfo(id, Enum.InfoType.GamePass):andThen(function(gamepassInfo)
						self:addBusinessEvent(player.UserId, {
							amount = gamepassInfo.PriceInRobux,
							itemType = "Gamepass",
							itemId = self:filterForBusinessEvent(gamepassInfo.Name),
							cartType = "Website",
						})
					end):catch(catchFactory("MarketplacePromise.promiseProductInfo")):await()
				end
			end

			Store.PlayerCache[player.UserId] = playerData
			Store.SavePlayerData(player)
		end
	end

	local playerEventQueue = initializationQueueByUserId[player.UserId]
	if playerEventQueue then
		initializationQueueByUserId[player.UserId] = nil
		for _, queuedFunction in ipairs(playerEventQueue) do
			local arguments = queuedFunction.Args
			queuedFunction.Func(table.unpack(arguments, 1, arguments.n))
		end

		Logger:information("Player initialization queue called #" .. #playerEventQueue .. " events")
	end
end

function GameAnalytics:PlayerRemoved(player: Player)
	-- Save
	Store.SavePlayerData(player)

	local playerData = Store.GetPlayerDataFromCache(player.UserId)
	if playerData then
		if not playerData.PlayerTeleporting then
			self:endSession(player.UserId)
		else
			Store.PlayerCache[player.UserId] = nil
		end
	end
end

function GameAnalytics:isPlayerReady(playerId: integer): boolean
	return not not Store.GetPlayerDataFromCache(playerId)
end

function GameAnalytics:ProcessReceiptCallback(information)
	MarketplacePromise.promiseProductInfo(information.ProductId, Enum.InfoType.Product):andThen(function(productInfo)
		self:addBusinessEvent(information.PlayerId, {
			amount = information.CurrencySpent,
			itemId = GameAnalytics:filterForBusinessEvent(productInfo.Name),
			itemType = "DeveloperProduct",
		})
	end):catch(catchFactory("MarketplacePromise.promiseProductInfo")):await()
end

--customGamepassInfo argument to optinaly provide our own name or price
function GameAnalytics:GamepassPurchased(player: Player, gamePassId: integer, customGamepassInfo)
	MarketplacePromise.promiseProductInfo(gamePassId, Enum.InfoType.GamePass):andThen(function(productInfo)
		local amount = 0
		local itemId = "GamePass"
		if customGamepassInfo then
			amount = customGamepassInfo.PriceInRobux
			itemId = customGamepassInfo.Name
		elseif productInfo then
			amount = productInfo.PriceInRobux
			itemId = productInfo.Name
		end

		self:addBusinessEvent(player.UserId, {
			amount = amount or 0,
			gamepassId = gamePassId,
			itemId = self:filterForBusinessEvent(itemId),
			itemType = "Gamepass",
		})
	end):catch(catchFactory("MarketplacePromise.promiseProductInfo")):await()
end

local requiredInitializationOptions = {"gameKey", "secretKey"}

function GameAnalytics:initialize(options: InitializeOptions)
	Threading:performTaskOnGAThread(function()
		for _, option in ipairs(requiredInitializationOptions) do
			if options[option] == nil then
				Logger:error("Initialize '" .. option .. "' option missing")
				return
			end
		end

		if options.enableInfoLog ~= nil and options.enableInfoLog then
			self:setEnabledInfoLog(options.enableInfoLog)
		end

		if options.enableVerboseLog ~= nil and options.enableVerboseLog then
			self:setEnabledVerboseLog(options.enableVerboseLog)
		end

		if options.availableCustomDimensions01 ~= nil and #options.availableCustomDimensions01 > 0 then
			self:configureAvailableCustomDimensions01(options.availableCustomDimensions01)
		end

		if options.availableCustomDimensions02 ~= nil and #options.availableCustomDimensions02 > 0 then
			self:configureAvailableCustomDimensions02(options.availableCustomDimensions02)
		end

		if options.availableCustomDimensions03 ~= nil and #options.availableCustomDimensions03 > 0 then
			self:configureAvailableCustomDimensions03(options.availableCustomDimensions03)
		end

		if options.availableResourceCurrencies ~= nil and #options.availableResourceCurrencies > 0 then
			self:configureAvailableResourceCurrencies(options.availableResourceCurrencies)
		end

		if options.availableResourceItemTypes ~= nil and #options.availableResourceItemTypes > 0 then
			self:configureAvailableResourceItemTypes(options.availableResourceItemTypes)
		end

		if options.build ~= nil and #options.build > 0 then
			self:configureBuild(options.build)
		end

		if options.availableGamepasses ~= nil and #options.availableGamepasses > 0 then
			self:configureAvailableGamepasses(options.availableGamepasses)
		end

		if options.enableDebugLog ~= nil then
			self:setEnabledDebugLog(options.enableDebugLog)
		end

		if options.automaticSendBusinessEvents ~= nil then
			self:setEnabledAutomaticSendBusinessEvents(options.automaticSendBusinessEvents)
		end

		if options.reportErrors ~= nil then
			self:setEnabledReportErrors(options.reportErrors)
		end

		if options.useCustomUserId ~= nil then
			self:setEnabledCustomUserId(options.useCustomUserId)
		end

		if isSdkReady({needsInitialized = true, shouldWarn = false}) then
			Logger:warning("SDK already initialized. Can only be called once.")
			return
		end

		local gameKey = options.gameKey
		local secretKey = options.secretKey

		if not Validation.validateKeys(gameKey, secretKey) then
			Logger:warning("SDK failed initialize. Game key or secret key is invalid. Can only contain characters A-z 0-9, gameKey is 32 length, secretKey is 40 length. Failed keys - gameKey: " .. gameKey .. ", secretKey: " .. secretKey)
			return
		end

		Events.GameKey = gameKey
		Events.SecretKey = secretKey

		State.Initialized = true

		-- New Players
		Players.PlayerAdded:Connect(function(player)
			self:PlayerJoined(player)
		end)

		-- Players leaving
		Players.PlayerRemoving:Connect(function(player)
			self:PlayerRemoved(player)
		end)

		-- Fire for players already in game
		for _, player in ipairs(Players:GetPlayers()) do
			Scheduler.FastSpawn(self.PlayerJoined, self, player)
		end

		for _, queuedFunction in ipairs(initializationQueue) do
			local arguments = queuedFunction.Args
			Scheduler_Spawn(queuedFunction.Func, table.unpack(arguments, 1, arguments.n))
		end

		Logger:information("Server initialization queue called #" .. #initializationQueue .. " events")
		initializationQueue = nil
		Events:processEventQueue()
	end)
end

if not ReplicatedStorage:FindFirstChild("GameAnalyticsRemoteConfigs") then
	-- Create
	local remoteEvent = Instance.new("RemoteEvent")
	remoteEvent.Name = "GameAnalyticsRemoteConfigs"
	remoteEvent.Parent = ReplicatedStorage
end

if not ReplicatedStorage:FindFirstChild("OnPlayerReadyEvent") then
	-- Create
	local bindableEvent = Instance.new("BindableEvent")
	bindableEvent.Name = "OnPlayerReadyEvent"
	bindableEvent.Parent = ReplicatedStorage
end

Scheduler_Spawn(function()
	local currentHour = math.floor(os.time() / 3600)
	errorDataStore = Store.GetErrorDataStore(currentHour)

	while true do
		Scheduler_Wait(ONE_HOUR_IN_SECONDS)
		currentHour = math.floor(os.time() / 3600)
		errorDataStore = Store.GetErrorDataStore(currentHour)
		errorCountCache = {}
		errorCountCacheKeys = {}
	end
end)

Scheduler_Spawn(function()
	while true do
		Scheduler_Wait(Store.AutoSaveData)
		for _, key in ipairs(errorCountCacheKeys) do
			local errorCount = errorCountCache[key]
			local step = errorCount.currentCount - errorCount.countInDS
			errorCountCache[key].countInDS = Store.IncrementErrorCount(errorDataStore, key, step)
			errorCountCache[key].currentCount = errorCountCache[key].countInDS
		end
	end
end)

local function errorHandler(message, trace, scriptName, player)
	local newMessage = scriptName .. ": message=" .. message .. ", trace=" .. trace
	if #newMessage > 8192 then
		newMessage = string.sub(newMessage, 1, 8192)
	end

	local userId = nil
	if player then
		userId = player.UserId
		newMessage = string.gsub(newMessage, player.Name, "[LocalPlayer]") -- so we don't flood the same errors with different player names
	end

	local key = newMessage
	if #key > 50 then
		key = string.sub(key, 1, 50)
	end

	if errorCountCache[key] == nil then
		table.insert(errorCountCacheKeys, key)
		errorCountCache[key] = {
			countInDS = 0,
			currentCount = 0,
		}
	end

	-- don't report error if limit has been exceeded
	if errorCountCache[key].currentCount > MAX_ERRORS_PER_HOUR then
		return
	end

	GameAnalytics:addErrorEvent(userId, {
		message = newMessage,
		severity = GameAnalytics.EGAErrorSeverity.error,
	})

	-- increment error count
	errorCountCache[key].currentCount += 1
end

local function errorHandlerFromServer(message, trace, erroringScript)
	-- Validate
	if not State.ReportErrors or not erroringScript then
		return
	end

	local scriptName = nil
	local success = pcall(function()
		scriptName = erroringScript:GetFullName() -- CoreGui.RobloxGui.Modules.PlayerList error, can't get name because of security permission
	end)

	if not success then
		return
	end

	return errorHandler(message, trace, scriptName)
end

local function errorHandlerFromClient(message, trace, scriptName, player)
	-- Validate
	if not State.ReportErrors then
		return
	end

	return errorHandler(message, trace, scriptName, player)
end

-- Error Logging
ScriptContext.Error:Connect(errorHandlerFromServer)
if not ReplicatedStorage:FindFirstChild("GameAnalyticsError") then
	-- Create
	local f = Instance.new("RemoteEvent")
	f.Name = "GameAnalyticsError"
	f.Parent = ReplicatedStorage
end

ReplicatedStorage.GameAnalyticsError.OnServerEvent:Connect(function(player, message, trace, scriptName)
	errorHandlerFromClient(message, trace, scriptName, player)
end)

-- Record Gamepasses.
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, purchased)
	-- Validate
	if not State.AutomaticSendBusinessEvents or not purchased then
		return
	end

	GameAnalytics:GamepassPurchased(player, gamePassId)
end)

return GameAnalytics
