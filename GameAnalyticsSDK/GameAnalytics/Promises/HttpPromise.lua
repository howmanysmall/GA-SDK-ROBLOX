local HttpService = game:GetService("HttpService")
local Promise = require(script.Parent.Parent.Vendor.Promise)
local t = require(script.Parent.Parent.Vendor.t)

local HttpPromise = {}

local IRequestDictionary = t.strictInterface({
	Body = t.optional(t.string);
	Headers = t.optional(t.table);
	Method = t.optional(t.literal("GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATH"));
	Url = t.string;
})

type Dictionary<Value> = {[string]: Value}

export type RequestDictionary = {
	Body: string?,
	Headers: Dictionary<string>?,
	Method: string?,
	Url: string?,
}

local function requestAsync(requestDictionary)
	return HttpService:RequestAsync(requestDictionary)
end

local function jsonEncode(data)
	return HttpService:JSONEncode(data)
end

local function jsonDecode(jsonString)
	return HttpService:JSONDecode(jsonString)
end

function HttpPromise.promiseRequest(requestDictionary: RequestDictionary)
	local typeSuccess, typeError = IRequestDictionary(requestDictionary)
	if not typeSuccess then
		return Promise.reject(typeError)
	end

	return Promise.defer(function(resolve, reject)
		local success, responseDictionaryOrError = pcall(requestAsync, requestDictionary);
		(success and resolve or reject)(responseDictionaryOrError)
	end)
end

function HttpPromise.promiseJsonEncode(data: any)
	return Promise.new(function(resolve, reject)
		local success, valueOrError = pcall(jsonEncode, data);
		(success and resolve or reject)(valueOrError)
	end)
end

function HttpPromise.promiseJsonDecode(jsonString: string)
	local typeSuccess, typeError = t.string(jsonString)
	if not typeSuccess then
		return Promise.reject(typeError)
	end

	return Promise.new(function(resolve, reject)
		local success, valueOrError = pcall(jsonDecode, jsonString);
		(success and resolve or reject)(valueOrError)
	end)
end

return HttpPromise
