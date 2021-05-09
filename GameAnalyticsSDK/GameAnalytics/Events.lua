local HttpService = game:GetService("HttpService")
local GAErrorSeverity = require(script.Parent.GAErrorSeverity)
local GAProgressionStatus = require(script.Parent.GAProgressionStatus)
local GAResourceFlowType = require(script.Parent.GAResourceFlowType)
local HttpApi = require(script.Parent.HttpApi)
local Logger = require(script.Parent.Logger)
local Store = require(script.Parent.Store)
local Threading = require(script.Parent.Threading)
local Utilities = require(script.Parent.Utilities)
local Validation = require(script.Parent.Validation)
local Version = require(script.Parent.Version)

local Events = {
	ProcessEventsInterval = 8,
	GameKey = "",
	SecretKey = "",
	Build = "",
	_availableResourceCurrencies = {},
	_availableResourceItemTypes = {},
}

local CATEGORY_BUSINESS = "business"
local CATEGORY_DESIGN = "design"
local CATEGORY_ERROR = "error"
local CATEGORY_PROGRESSION = "progression"
local CATEGORY_RESOURCE = "resource"
local CATEGORY_SDK_ERROR = "sdk_error"
local CATEGORY_SESSION_END = "session_end"
local CATEGORY_SESSION_START = "user"
local DUMMY_SESSION_ID = string.lower(HttpService:GenerateGUID(false))
local MAX_AGGREGATED_EVENTS = 2000
local MAX_EVENTS_TO_SEND_IN_ONE_BATCH = 500

local function addDimensionsToEvent(playerId, eventData)
	if not eventData or not playerId then
		return
	end

	local playerData = Store.getPlayerDataFromCache(playerId)

	-- add to dict (if not nil)
	if playerData and playerData.CurrentCustomDimension01 and #playerData.CurrentCustomDimension01 > 0 then
		eventData.custom_01 = playerData.CurrentCustomDimension01
	end

	if playerData and playerData.CurrentCustomDimension02 and #playerData.CurrentCustomDimension02 > 0 then
		eventData.custom_02 = playerData.CurrentCustomDimension02
	end

	if playerData and playerData.CurrentCustomDimension03 and #playerData.CurrentCustomDimension03 > 0 then
		eventData.custom_03 = playerData.CurrentCustomDimension03
	end
end

local function getClientTsAdjusted(playerId)
	if not playerId then
		return os.time()
	end

	local playerData = Store.getPlayerDataFromCache(playerId)
	local clientTs = os.time()
	local clientTsAdjustedInteger = clientTs + playerData.ClientServerTimeOffset
	if Validation.validateClientTs(clientTsAdjustedInteger) then
		return clientTsAdjustedInteger
	else
		return clientTs
	end
end

local function getEventAnnotations(playerId)
	local playerData
	local id

	if playerId then
		id = playerId
		playerData = Store.getPlayerDataFromCache(playerId)
	else
		id = "DummyId"
		playerData = {
			OS = "uwp_desktop 0.0.0",
			Platform = "uwp_desktop",
			SessionID = DUMMY_SESSION_ID,
			Sessions = 1,
			CustomUserId = "Server",
		}
	end

	local annotations = {
		-- ---- REQUIRED ----
		-- collector event API version
		v = 2,
		-- User identifier
		user_id = tostring(id) .. playerData.CustomUserId,
		-- Client Timestamp (the adjusted timestamp)
		client_ts = getClientTsAdjusted(playerId),
		-- SDK version
		sdk_version = "roblox " .. Version.SdkVersion,
		-- Operation system version
		os_version = playerData.OS,
		-- Device make (hardcoded to apple)
		manufacturer = "unknown",
		-- Device version
		device = "unknown",
		-- Platform (operating system)
		platform = playerData.Platform,
		-- Session identifier
		session_id = playerData.SessionID,
		-- Session number
		session_num = playerData.Sessions,
	}

	if not Utilities.isStringNullOrEmpty(playerData.CountryCode) then
		annotations.country_code = playerData.CountryCode
	else
		annotations.country_code = "unknown"
	end

	if Validation.validateBuild(Events.Build) then
		annotations.build = Events.Build
	end

	if playerData.Configurations and next(playerData.Configurations) ~= nil then
		annotations.configurations = playerData.Configurations
	end

	if not Utilities.isStringNullOrEmpty(playerData.AbId) then
		annotations.ab_id = playerData.AbId
	end

	if not Utilities.isStringNullOrEmpty(playerData.AbVariantId) then
		annotations.ab_variant_id = playerData.AbVariantId
	end

	return annotations
end

local function addEventToStore(playerId, eventData)
	-- Get default annotations
	local eventAnnotations = getEventAnnotations(playerId)

	-- Merge with eventData
	for key in pairs(eventData) do
		eventAnnotations[key] = eventData[key]
	end

	-- Create json string representation
	local json = HttpService:JSONEncode(eventAnnotations)

	-- output if VERBOSE LOG enabled
	Logger:verboseInformation("Event added to queue: " .. json)

	-- Add to store
	table.insert(Store.EventsQueue, eventAnnotations)
end

local function dequeueMaxEvents()
	if #Store.EventsQueue <= MAX_EVENTS_TO_SEND_IN_ONE_BATCH then
		local eventsQueue = Store.EventsQueue
		Store.EventsQueue = {}
		return eventsQueue
	else
		Logger:warning(string.format("More than %d events queued! Sending %d.", MAX_EVENTS_TO_SEND_IN_ONE_BATCH, MAX_EVENTS_TO_SEND_IN_ONE_BATCH))

		if #Store.EventsQueue > MAX_AGGREGATED_EVENTS then
			Logger:warning(string.format("DROPPING EVENTS: More than %d events queued!", MAX_AGGREGATED_EVENTS))
		end

		-- Expensive operation to get ordered events cleared out (O(n))
		local eventsQueue = table.move(Store.EventsQueue, 1, MAX_EVENTS_TO_SEND_IN_ONE_BATCH, 1, table.create(MAX_EVENTS_TO_SEND_IN_ONE_BATCH))

		-- Shift everything down and overwrite old events
		local eventCount = #Store.EventsQueue
		for index = 1, math.min(MAX_AGGREGATED_EVENTS, eventCount) do
			Store.EventsQueue[index] = Store.EventsQueue[index + MAX_EVENTS_TO_SEND_IN_ONE_BATCH]
		end

		-- Clear additional events
		for index = MAX_AGGREGATED_EVENTS + 1, eventCount do
			Store.EventsQueue[index] = nil
		end

		return eventsQueue
	end
end

local function processEvents()
	local queue = dequeueMaxEvents()

	if #queue == 0 then
		Logger:information("Event queue: No events to send")
		return
	end

	-- Log
	Logger:information("Event queue: Sending " .. tostring(#queue) .. " events.")

	local eventsResult = HttpApi:sendEventsInArray(Events.GameKey, Events.SecretKey, queue)
	local statusCode = eventsResult.statusCode
	local responseBody = eventsResult.body

	if statusCode == HttpApi.EGAHTTPApiResponse.Ok and responseBody then
		Logger:information("Event queue: " .. tostring(#queue) .. " events sent.")
	else
		if statusCode == HttpApi.EGAHTTPApiResponse.NoResponse then
			Logger:warning("Event queue: Failed to send events to collector - Retrying next time")
			for _, queuedEvent in ipairs(queue) do
				if #Store.EventsQueue < MAX_AGGREGATED_EVENTS then
					table.insert(Store.EventsQueue, queuedEvent)
				else
					break
				end
			end
		else
			if statusCode == HttpApi.EGAHTTPApiResponse.BadRequest and responseBody then
				Logger:warning("Event queue: " .. tostring(#queue) .. " events sent. " .. tostring(#responseBody) .. " events failed GA server validation.")
			else
				Logger:warning("Event queue: Failed to send events.")
			end
		end
	end
end

function Events:processEventQueue()
	processEvents()
	Threading:scheduleTimer(self.ProcessEventsInterval, function()
		self:processEventQueue()
	end)
end

function Events:setBuild(build)
	if not Validation.validateBuild(build) then
		Logger:warning("Validation fail - configure build: Cannot be null, empty or above 32 length. String: " .. build)
		return
	end

	self.Build = build
	Logger:information("Set build version: " .. build)
end

function Events:setAvailableResourceCurrencies(availableResourceCurrencies)
	if not Validation.validateResourceCurrencies(availableResourceCurrencies) then
		return
	end

	self._availableResourceCurrencies = availableResourceCurrencies
	Logger:information("Set available resource currencies: (" .. table.concat(availableResourceCurrencies, ", ") .. ")")
end

function Events:setAvailableResourceItemTypes(availableResourceItemTypes)
	if not Validation.validateResourceCurrencies(availableResourceItemTypes) then
		return
	end

	self._availableResourceItemTypes = availableResourceItemTypes
	Logger:information("Set available resource item types: (" .. table.concat(availableResourceItemTypes, ", ") .. ")")
end

function Events:addSessionStartEvent(playerId, teleportData)
	local playerData = Store.getPlayerDataFromCache(playerId)
	if teleportData then
		playerData.Sessions = teleportData.Sessions
	else
		local eventData = {category = CATEGORY_SESSION_START}

		-- Increment session number and persist
		playerData.Sessions += 1

		-- Add custom dimensions
		addDimensionsToEvent(playerId, eventData)

		-- Add to store
		addEventToStore(playerId, eventData)
		Logger:information("Add SESSION START event")
		processEvents()
	end
end

function Events:addSessionEndEvent(playerId)
	local playerData = Store.getPlayerDataFromCache(playerId)
	local sessionStartTimestamp = playerData.SessionStart
	local clientTimestampAdjusted = getClientTsAdjusted(playerId)
	local sessionLength = 0

	if clientTimestampAdjusted ~= nil and sessionStartTimestamp ~= nil then
		sessionLength = clientTimestampAdjusted - sessionStartTimestamp
	end

	if sessionLength < 0 then
		-- Should never happen.
		-- Could be because of edge cases regarding time altering on device.
		Logger:warning("Session length was calculated to be less then 0. Should not be possible. Resetting to 0.")
		sessionLength = 0
	end

	-- Event specific data
	local eventData = {
		category = CATEGORY_SESSION_END,
		length = sessionLength,
	}

	-- Add custom dimensions
	addDimensionsToEvent(playerId, eventData)

	-- Add to store
	addEventToStore(playerId, eventData)
	playerData.SessionStart = 0

	Logger:information("Add SESSION END event.")
	processEvents()
end

function Events:addBusinessEvent(playerId, currency, amount, itemType, itemId, cartType)
	-- Validate event params
	if not Validation.validateBusinessEvent(currency, amount, cartType, itemType, itemId) then
		-- TODO: add sdk error event
		return
	end

	-- Increment transaction number and persist
	local playerData = Store.getPlayerDataFromCache(playerId)
	playerData.Transactions += 1

	-- Required
	local eventData = {
		amount = amount,
		cart_type = nil,
		category = CATEGORY_BUSINESS,
		currency = currency,
		event_id = itemType .. ":" .. itemId,
		transaction_num = playerData.Transactions,
	}

	-- Optional
	if not Utilities.isStringNullOrEmpty(cartType) then
		eventData.cart_type = cartType
	end

	-- Add custom dimensions
	addDimensionsToEvent(playerId, eventData)
	Logger:information("Add BUSINESS event: {currency:" .. currency .. ", amount:" .. tostring(amount) .. ", itemType:" .. itemType .. ", itemId:" .. itemId .. ", cartType:" .. cartType .. "}")

	-- Send to store
	addEventToStore(playerId, eventData)
end

function Events:addResourceEvent(playerId, flowType, currency, amount, itemType, itemId)
	-- Validate event params
	if not Validation.validateResourceEvent(GAResourceFlowType, flowType, currency, amount, itemType, itemId, self._availableResourceCurrencies, self._availableResourceItemTypes) then
		-- TODO: add sdk error event
		return
	end

	-- If flow type is sink reverse amount
	if flowType == GAResourceFlowType.Sink then
		amount = -1 * amount
	end

	-- insert event specific values
	local flowTypeString = GAResourceFlowType[flowType]
	local eventData = {
		amount = amount,
		category = CATEGORY_RESOURCE,
		event_id = flowTypeString .. ":" .. currency .. ":" .. itemType .. ":" .. itemId,
	}

	-- Add custom dimensions
	addDimensionsToEvent(playerId, eventData)

	Logger:information("Add RESOURCE event: {currency:" .. currency .. ", amount:" .. tostring(amount) .. ", itemType:" .. itemType .. ", itemId:" .. itemId .. "}")

	-- Send to store
	addEventToStore(playerId, eventData)
end

function Events:addProgressionEvent(playerId, progressionStatus, progression01, progression02, progression03, score)
	-- Validate event params
	if not Validation.validateProgressionEvent(GAProgressionStatus, progressionStatus, progression01, progression02, progression03) then
		-- TODO: add sdk error event
		return
	end

	-- Progression identifier
	local progressionIdentifier
	if Utilities.isStringNullOrEmpty(progression02) then
		progressionIdentifier = progression01
	elseif Utilities.isStringNullOrEmpty(progression03) then
		progressionIdentifier = progression01 .. ":" .. progression02
	else
		progressionIdentifier = progression01 .. ":" .. progression02 .. ":" .. progression03
	end

	local statusString = GAProgressionStatus[progressionStatus]
	local eventData = {
		attempt_num = nil,
		category = CATEGORY_PROGRESSION,
		event_id = statusString .. ":" .. progressionIdentifier,
		score = nil,
	}

	-- Attempt
	local attemptNumber = 0

	-- Add score if specified and status is not start
	if score ~= nil and progressionStatus ~= GAProgressionStatus.Start then
		eventData.score = score
	end

	local playerData = Store.getPlayerDataFromCache(playerId)

	-- Count attempts on each progression fail and persist
	if progressionStatus == GAProgressionStatus.Fail then
		-- Increment attempt number
		local progressionTries = playerData.ProgressionTries[progressionIdentifier] or 0
		playerData.ProgressionTries[progressionIdentifier] = progressionTries + 1
	end

	-- increment and add attempt_num on complete and delete persisted
	if progressionStatus == GAProgressionStatus.Complete then
		-- Increment attempt number
		local progressionTries = playerData.ProgressionTries[progressionIdentifier] or 0
		playerData.ProgressionTries[progressionIdentifier] = progressionTries + 1

		-- Add to event
		attemptNumber = playerData.ProgressionTries[progressionIdentifier]
		eventData.attempt_num = attemptNumber

		-- Clear
		playerData.ProgressionTries[progressionIdentifier] = 0
	end

	-- Add custom dimensions
	addDimensionsToEvent(playerId, eventData)

	local progression02String = ""
	if not Utilities.isStringNullOrEmpty(progression02) then
		progression02String = progression02
	end

	local progression03String = ""
	if not Utilities.isStringNullOrEmpty(progression03) then
		progression03String = progression03
	end

	Logger:information("Add PROGRESSION event: {status:" .. statusString .. ", progression01:" .. progression01 .. ", progression02:" .. progression02String .. ", progression03:" .. progression03String .. ", score:" .. tostring(score) .. ", attempt:" .. tostring(attemptNumber) .. "}")

	-- Send to store
	addEventToStore(playerId, eventData)
end

function Events:addDesignEvent(playerId, eventId, value)
	-- Validate
	if not Validation.validateDesignEvent(eventId) then
		-- TODO: add sdk error event
		return
	end

	-- Create empty eventData
	local eventData = {
		category = CATEGORY_DESIGN,
		event_id = eventId,
		value = nil,
	}

	if value ~= nil then
		eventData.value = value
	end

	-- Add custom dimensions
	addDimensionsToEvent(playerId, eventData)
	Logger:information("Add DESIGN event: {eventId:" .. eventId .. ", value:" .. tostring(value) .. "}")

	-- Send to store
	addEventToStore(playerId, eventData)
end

function Events:addErrorEvent(playerId, severity, message)
	-- Validate
	if not Validation.validateErrorEvent(GAErrorSeverity, severity, message) then
		-- TODO: add sdk error event
		return
	end

	-- Create empty eventData
	local severityString = GAErrorSeverity[severity]
	local eventData = {
		category = CATEGORY_ERROR,
		message = message,
		severity = severityString,
	}

	-- Add custom dimensions
	addDimensionsToEvent(playerId, eventData)

	local messageString = ""
	if not Utilities.isStringNullOrEmpty(message) then
		messageString = message
	end

	Logger:information("Add ERROR event: {severity:" .. severityString .. ", message:" .. messageString .. "}")

	-- Send to store
	addEventToStore(playerId, eventData)
end

function Events:addSdkErrorEvent(playerId, category, area, action, parameter, reason)
	-- Create empty eventData
	local eventData = {
		category = CATEGORY_SDK_ERROR,
		error_action = action,
		error_area = area,
		error_category = category,
		error_parameter = nil,
		reason = nil,
	}

	if not Utilities.isStringNullOrEmpty(parameter) then
		eventData.error_parameter = parameter
	end

	if not Utilities.isStringNullOrEmpty(reason) then
		eventData.reason = reason
	end

	Logger:information("Add SDK ERROR event: {error_category:" .. category .. ", error_area:" .. area .. ", error_action:" .. action .. "}")

	-- Send to store
	addEventToStore(playerId, eventData)
end

return Events
