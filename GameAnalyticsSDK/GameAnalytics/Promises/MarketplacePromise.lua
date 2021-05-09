local MarketplaceService = game:GetService("MarketplaceService")
local Promise = require(script.Parent.Parent.Vendor.Promise)
local t = require(script.Parent.Parent.Vendor.t)

local MarketplacePromise = {}

local function userOwnsGamePassAsync(userId: number, gamePassId: number)
	return MarketplaceService:UserOwnsGamePassAsync(userId, gamePassId)
end

local function getProductInfo(assetId: number, infoType: Enum.InfoType?)
	return MarketplaceService:GetProductInfo(assetId, infoType)
end

local productCache = {}
for _, infoType in ipairs(Enum.InfoType:GetEnumItems()) do
	productCache[infoType] = {}
end

local promiseUserOwnsGamePassTuple = t.tuple(t.union(t.instanceIsA("Player"), t.integer), t.integer)
local promiseProductInfoTuple = t.tuple(t.integer, t.optional(t.enum(Enum.InfoType)))

function MarketplacePromise.promiseUserOwnsGamePass(playerOrUserId: Player | number, gamePassId: number)
	local typeSuccess, typeError = promiseUserOwnsGamePassTuple(playerOrUserId, gamePassId)
	if not typeSuccess then
		return Promise.reject(typeError)
	end

	local userId = type(playerOrUserId) == "number" and playerOrUserId or playerOrUserId.UserId
	return Promise.defer(function(resolve, reject)
		local success, valueOrError = pcall(userOwnsGamePassAsync, userId, gamePassId);
		(success and resolve or reject)(valueOrError)
	end)
end

function MarketplacePromise.promiseProductInfo(assetId: number, infoType: Enum.InfoType?)
	local typeSuccess, typeError = promiseProductInfoTuple(assetId, infoType)
	if not typeSuccess then
		return Promise.reject(typeError)
	end

	infoType = infoType or Enum.InfoType.Asset
	local cacheTable = productCache[infoType]
	local cachedResult = cacheTable[assetId]
	if cachedResult ~= nil then
		return Promise.resolve(cachedResult)
	end

	return Promise.defer(function(resolve, reject)
		local success, valueOrError = pcall(getProductInfo, assetId, infoType)
		if success then
			cacheTable[assetId] = valueOrError
			resolve(valueOrError)
		else
			reject(valueOrError)
		end
	end)
end

return MarketplacePromise
