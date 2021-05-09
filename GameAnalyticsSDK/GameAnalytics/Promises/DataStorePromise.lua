local DataStoreService: DataStoreService = require(script.Parent.Parent.Vendor.DataStoreService)
local Promise = require(script.Parent.Parent.Vendor.Promise)
local t = require(script.Parent.Parent.Vendor.t)

local DataStorePromise = {}

local function getDataStore(name: string, scope: string?)
	return DataStoreService:GetDataStore(name, scope)
end

local function getAsync(dataStore: DataStore, key: string)
	return dataStore:GetAsync(key)
end

local function setAsync(dataStore: DataStore, key: string, value: any)
	return dataStore:SetAsync(key, value)
end

local function incrementAsync(dataStore: DataStore, key: string, delta: number?)
	return dataStore:IncrementAsync(key, delta)
end

local isDataStore = t.union(t.instanceIsA("DataStore"), t.table) -- have to support MockDataStoreService as well.
local validKeys = t.union(t.string, t.number)
local promiseDataStoreTuple = t.tuple(t.string, t.optional(t.string))
local promiseGetTuple = t.tuple(isDataStore, validKeys)
local promiseSetTuple = t.tuple(isDataStore, validKeys, t.any)
local promiseIncrementTuple = t.tuple(isDataStore, validKeys, t.optional(t.integer))

function DataStorePromise.promiseDataStore(name: string, scope: string?)
	local typeSuccess, typeError = promiseDataStoreTuple(name, scope)
	if not typeSuccess then
		return Promise.reject(typeError)
	end

	return Promise.new(function(resolve, reject)
		local success, valueOrError = pcall(getDataStore, name, scope);
		(success and resolve or reject)(valueOrError)
	end)
end

function DataStorePromise.promiseGet(dataStore: DataStore, key: string)
	local typeSuccess, typeError = promiseGetTuple(dataStore, key)
	if not typeSuccess then
		return Promise.reject(typeError)
	end

	return Promise.defer(function(resolve, reject)
		local success, valueOrError = pcall(getAsync, dataStore, key);
		(success and resolve or reject)(valueOrError)
	end)
end

function DataStorePromise.promiseSet(dataStore: DataStore, key: string, value: any)
	local typeSuccess, typeError = promiseSetTuple(dataStore, key, value)
	if not typeSuccess then
		return Promise.reject(typeError)
	end

	return Promise.defer(function(resolve, reject)
		local success, valueOrError = pcall(setAsync, dataStore, key, value);
		(success and resolve or reject)(valueOrError)
	end)
end

function DataStorePromise.promiseIncrement(dataStore: DataStore, key: string, delta: number?)
	local typeSuccess, typeError = promiseIncrementTuple(dataStore, key, delta)
	if not typeSuccess then
		return Promise.reject(typeError)
	end

	return Promise.defer(function(resolve, reject)
		local success, valueOrError = pcall(incrementAsync, dataStore, key, delta);
		(success and resolve or reject)(valueOrError)
	end)
end

return DataStorePromise
