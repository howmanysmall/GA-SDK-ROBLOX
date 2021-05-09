local HttpService = game:GetService("HttpService")
local Events = require(script.Parent.Events)
local HttpApi = require(script.Parent.HttpApi)
local Logger = require(script.Parent.Logger)
local Store = require(script.Parent.Store)
local Validation = require(script.Parent.Validation)

local State = {
	_availableCustomDimensions01 = {},
	_availableCustomDimensions02 = {},
	_availableCustomDimensions03 = {},
	_availableGamepasses = {},
	_enableEventSubmission = true,
	Initialized = false,
	ReportErrors = true,
	UseCustomUserId = false,
	AutomaticSendBusinessEvents = true,
	ConfigsHash = "",
}

local GameAnalyticsRemoteConfigs

local function getClientTsAdjusted(playerId)
	local PlayerData = Store.GetPlayerDataFromCache(playerId)
	if not PlayerData then
		return os.time()
	end

	local clientTs = os.time()
	local clientTsAdjustedInteger = clientTs + PlayerData.ClientServerTimeOffset
	if Validation.validateClientTs(clientTsAdjustedInteger) then
		return clientTsAdjustedInteger
	else
		return clientTs
	end
end

local function populateConfigurations(player)
	local PlayerData = Store.GetPlayerDataFromCache(player.UserId)
	local sdkConfig = PlayerData.SdkConfig

	if sdkConfig.configs then
		local configurations = sdkConfig.configs

		for _, configuration in pairs(configurations) do
			if configuration then
				local key = configuration.key or ""
				local start_ts = configuration.start_ts or 0
				local end_ts = configuration.end_ts or math.huge
				local client_ts_adjusted = getClientTsAdjusted(player.UserId)

				if #key > 0 and configuration.value and client_ts_adjusted > start_ts and client_ts_adjusted < end_ts then
					PlayerData.Configurations[key] = configuration.value
					Logger:debug("configuration added: key=" .. configuration.key .. ", value=" .. configuration.value)
				end
			end
		end
	end

	Logger:information("Remote configs populated")

	PlayerData.RemoteConfigsIsReady = true
	GameAnalyticsRemoteConfigs = GameAnalyticsRemoteConfigs or game:GetService("ReplicatedStorage"):WaitForChild("GameAnalyticsRemoteConfigs")
	GameAnalyticsRemoteConfigs:FireClient(player, PlayerData.Configurations)
end

function State:sessionIsStarted(playerId)
	local PlayerData = Store.GetPlayerDataFromCache(playerId)
	if not PlayerData then
		return false
	end

	return PlayerData.SessionStart ~= 0
end

function State:isEnabled(playerId)
	local PlayerData = Store.GetPlayerDataFromCache(playerId)
	if not PlayerData or not PlayerData.InitAuthorized then
		return false
	else
		return true
	end
end

function State:validateAndFixCurrentDimensions(playerId)
	local PlayerData = Store.GetPlayerDataFromCache(playerId)

	-- validate that there are no current dimension01 not in list
	if not Validation.validateDimension(self._availableCustomDimensions01, PlayerData.CurrentCustomDimension01) then
		Logger:debug("Invalid dimension01 found in variable. Setting to nil. Invalid dimension: " .. PlayerData.CurrentCustomDimension01)
	end

	-- validate that there are no current dimension02 not in list
	if not Validation.validateDimension(self._availableCustomDimensions02, PlayerData.CurrentCustomDimension02) then
		Logger:debug("Invalid dimension02 found in variable. Setting to nil. Invalid dimension: " .. PlayerData.CurrentCustomDimension02)
	end

	-- validate that there are no current dimension03 not in list
	if not Validation.validateDimension(self._availableCustomDimensions03, PlayerData.CurrentCustomDimension03) then
		Logger:debug("Invalid dimension03 found in variable. Setting to nil. Invalid dimension: " .. PlayerData.CurrentCustomDimension03)
	end
end

function State:setAvailableCustomDimensions01(availableCustomDimensions)
	if not Validation.validateCustomDimensions(availableCustomDimensions) then
		return
	end

	self._availableCustomDimensions01 = availableCustomDimensions
	Logger:information("Set available custom01 dimension values: (" .. table.concat(availableCustomDimensions, ", ") .. ")")
end

function State:setAvailableCustomDimensions02(availableCustomDimensions)
	if not Validation.validateCustomDimensions(availableCustomDimensions) then
		return
	end

	self._availableCustomDimensions02 = availableCustomDimensions
	Logger:information("Set available custom02 dimension values: (" .. table.concat(availableCustomDimensions, ", ") .. ")")
end

function State:setAvailableCustomDimensions03(availableCustomDimensions)
	if not Validation.validateCustomDimensions(availableCustomDimensions) then
		return
	end

	self._availableCustomDimensions03 = availableCustomDimensions
	Logger:information("Set available custom03 dimension values: (" .. table.concat(availableCustomDimensions, ", ") .. ")")
end

function State:setAvailableGamepasses(availableGamepasses)
	self._availableGamepasses = availableGamepasses
	Logger:information("Set available game passes: (" .. table.concat(availableGamepasses, ", ") .. ")")
end

function State:setEventSubmission(flag)
	self._enableEventSubmission = flag
end

function State:isEventSubmissionEnabled()
	return self._enableEventSubmission
end

function State:setCustomDimension01(playerId, dimension)
	local PlayerData = Store.GetPlayerDataFromCache(playerId)
	PlayerData.CurrentCustomDimension01 = dimension
end

function State:setCustomDimension02(playerId, dimension)
	local PlayerData = Store.GetPlayerDataFromCache(playerId)
	PlayerData.CurrentCustomDimension02 = dimension
end

function State:setCustomDimension03(playerId, dimension)
	local PlayerData = Store.GetPlayerDataFromCache(playerId)
	PlayerData.CurrentCustomDimension03 = dimension
end

function State:startNewSession(player, teleportData)
	if self:isEventSubmissionEnabled() then
		Logger:information("Starting a new session.")
	end

	local PlayerData = Store.GetPlayerDataFromCache(player.UserId)

	-- make sure the current custom dimensions are valid
	self:validateAndFixCurrentDimensions(player.UserId)

	local initResult = HttpApi:initRequest(Events.GameKey, Events.SecretKey, Events.Build, PlayerData, player.UserId)
	local statusCode = initResult.statusCode
	local responseBody = initResult.body

	if (statusCode == HttpApi.EGAHTTPApiResponse.Ok or statusCode == HttpApi.EGAHTTPApiResponse.Created) and responseBody then
		-- set the time offset - how many seconds the local time is different from servertime
		local timeOffsetSeconds = 0
		local serverTs = responseBody.server_ts or -1
		if serverTs > 0 then
			local clientTs = os.time()
			timeOffsetSeconds = serverTs - clientTs
		end

		responseBody.time_offset = timeOffsetSeconds
		if statusCode ~= HttpApi.EGAHTTPApiResponse.Created then
			local sdkConfig = PlayerData.SdkConfig

			if sdkConfig.configs then
				responseBody.configs = sdkConfig.configs
			end

			if sdkConfig.ab_id then
				responseBody.ab_id = sdkConfig.ab_id
			end

			if sdkConfig.ab_variant_id then
				responseBody.ab_variant_id = sdkConfig.ab_variant_id
			end
		end

		PlayerData.SdkConfig = responseBody
		PlayerData.InitAuthorized = true
	elseif statusCode == HttpApi.EGAHTTPApiResponse.Unauthorized then
		Logger:warning("Initialize SDK failed - Unauthorized")
		PlayerData.InitAuthorized = false
	else
		-- log the status if no connection
		if statusCode == HttpApi.EGAHTTPApiResponse.NoResponse or statusCode == HttpApi.EGAHTTPApiResponse.RequestTimeout then
			Logger:information("Init call (session start) failed - no response. Could be offline or timeout.")
		elseif statusCode == HttpApi.EGAHTTPApiResponse.BadResponse or statusCode == HttpApi.EGAHTTPApiResponse.JsonEncodeFailed or statusCode == HttpApi.EGAHTTPApiResponse.JsonDecodeFailed then
			Logger:information("Init call (session start) failed - bad response. Could be bad response from proxy or GA servers.")
		elseif statusCode == HttpApi.EGAHTTPApiResponse.BadRequest or statusCode == HttpApi.EGAHTTPApiResponse.UnknownResponseCode then
			Logger:information("Init call (session start) failed - bad request or unknown response.")
		end

		PlayerData.InitAuthorized = true
	end

	-- set offset in state (memory) from current config (config could be from cache etc.)
	PlayerData.ClientServerTimeOffset = PlayerData.SdkConfig.time_offset or 0
	PlayerData.ConfigsHash = PlayerData.SdkConfig.configs_hash or ""
	PlayerData.AbId = PlayerData.SdkConfig.ab_id or ""
	PlayerData.AbVariantId = PlayerData.SdkConfig.ab_variant_id or ""

	-- populate configurations
	populateConfigurations(player)

	if not self:isEnabled(player.UserId) then
		Logger:warning("Could not start session: SDK is disabled.")
		return
	end

	if teleportData then
		PlayerData.SessionID = teleportData.SessionID
		PlayerData.SessionStart = teleportData.SessionStart
	else
		PlayerData.SessionID = string.lower(HttpService:GenerateGUID(false))
		PlayerData.SessionStart = getClientTsAdjusted(player.UserId)
	end

	if self:isEventSubmissionEnabled() then
		Events:addSessionStartEvent(player.UserId, teleportData)
	end
end

function State:endSession(playerId)
	if self.Initialized and self:isEventSubmissionEnabled() then
		Logger:information("Ending session.")
		if self:isEnabled(playerId) and self:sessionIsStarted(playerId) then
			Events:addSessionEndEvent(playerId)
			Store.PlayerCache[playerId] = nil
		end
	end
end

function State:getRemoteConfigsStringValue(playerId, key, defaultValue)
	local PlayerData = Store.GetPlayerDataFromCache(playerId)
	return PlayerData.Configurations[key] or defaultValue
end

function State:isRemoteConfigsReady(playerId)
	local PlayerData = Store.GetPlayerDataFromCache(playerId)
	return PlayerData.RemoteConfigsIsReady
end

function State:getRemoteConfigsContentAsString(playerId)
	local PlayerData = Store.GetPlayerDataFromCache(playerId)
	return HttpService:JSONEncode(PlayerData.Configurations)
end

return State
