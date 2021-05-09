local DataStorePromise = require(script.Parent.Promises.DataStorePromise)
local DataStoreService = require(script.Parent.Vendor.DataStoreService)
local catchFactory = require(script.Parent.Promises.catchFactory)

local Store = {
	PlayerDS = DataStoreService:GetDataStore("GA_PlayerDS_1.0.0"),
	AutoSaveData = 180, -- Set to 0 to disable
	BasePlayerData = {
		Sessions = 0,
		Transactions = 0,
		ProgressionTries = {},
		CurrentCustomDimension01 = "",
		CurrentCustomDimension02 = "",
		CurrentCustomDimension03 = "",
		ConfigsHash = "",
		AbId = "",
		AbVariantId = "",
		InitAuthorized = false,
		SdkConfig = {},
		ClientServerTimeOffset = 0,
		Configurations = {},
		RemoteConfigsIsReady = false,
		PlayerTeleporting = false,
		OwnedGamepasses = nil, -- nil means a completely new player. {} means player with no game passes
		CountryCode = "",
		CustomUserId = "",
	},

	DataToSave = {
		"Sessions",
		"Transactions",
		"ProgressionTries",
		"CurrentCustomDimension01",
		"CurrentCustomDimension02",
		"CurrentCustomDimension03",
		"OwnedGamepasses",
	},

	-- Cache
	PlayerCache = {},
	EventsQueue = {},
}

function Store.getPlayerData(player: Player)
	local success, playerData = DataStorePromise.promiseGet(Store.PlayerDS, player.UserId):catch(catchFactory("DataStorePromise.promiseGet")):await()
	if not success then
		playerData = {}
	end

	return playerData
end

function Store.getPlayerDataFromCache(userId: number)
	local playerData = Store.PlayerCache[tonumber(userId)]
	if playerData then
		return playerData
	end

	playerData = Store.PlayerCache[tostring(userId)]
	return playerData
end

function Store.getErrorDataStore(scope: string?): DataStore
	local success, errorDataStore = DataStorePromise.promiseDataStore("GA_ErrorDS_1.0.0", scope):catch(catchFactory("DataStorePromise.promiseDataStore")):await()
	if not success then
		errorDataStore = {}
	end

	return errorDataStore
end

function Store.savePlayerData(player: Player)
	-- Variables
	local playerData = Store.getPlayerDataFromCache(player.UserId)
	local savePlayerData = {}
	if not playerData then
		return
	end

	-- Fill
	for _, key in pairs(Store.DataToSave) do
		savePlayerData[key] = playerData[key]
	end

	-- TODO: Convert this to UpdateAsync?
	-- Save
	DataStorePromise.promiseSet(Store.PlayerDS, player.UserId, savePlayerData):catch(catchFactory("DataStorePromise.promiseSet")):await()
end

function Store.incrementErrorCount(errorDataStore: DataStore, errorKey: string, step: number?)
	if not errorKey then
		return
	end

	-- Increment count
	local success, count = DataStorePromise.promiseIncrement(errorDataStore, errorKey, step):catch(catchFactory("DataStorePromise.promiseIncrement")):await()
	if not success then
		count = 0
	end

	return count
end

return Store
