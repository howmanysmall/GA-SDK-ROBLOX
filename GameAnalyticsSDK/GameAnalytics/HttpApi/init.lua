local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local HashLib = require(script.HashLib)
local HttpPromise = require(script.Parent.Vendor.HttpPromise)
local Logger = require(script.Parent.Logger)
local Validation = require(script.Parent.Validation)
local Version = require(script.Parent.Version)

local HttpApi = {
	protocol = "https",
	hostName = "api.gameanalytics.com",
	version = "v2",
	remoteConfigsVersion = "v1",
	initializeUrlPath = "init",
	eventsUrlPath = "events",
	EGAHTTPApiResponse = {
		NoResponse = 0,
		BadResponse = 1,
		RequestTimeout = 2,
		JsonEncodeFailed = 3,
		JsonDecodeFailed = 4,
		InternalServerError = 5,
		BadRequest = 6,
		Unauthorized = 7,
		UnknownResponseCode = 8,
		Ok = 9,
		Created = 10,
	},
}

local baseUrl = (RunService:IsStudio() and "http" or HttpApi.protocol) .. "://" .. (RunService:IsStudio() and "sandbox-" or "") .. HttpApi.hostName .. "/" .. HttpApi.version
local remoteConfigsBaseUrl = (RunService:IsStudio() and "http" or HttpApi.protocol) .. "://" .. (RunService:IsStudio() and "sandbox-" or "") .. HttpApi.hostName .. "/remote_configs/" .. HttpApi.remoteConfigsVersion

local function getInitAnnotations(build, playerData, playerId)
	local initAnnotations = {
		user_id = tostring(playerId) .. playerData.CustomUserId,
		sdk_version = "roblox " .. Version.SdkVersion,
		os_version = playerData.OS,
		platform = playerData.Platform,
		build = build,
		session_num = playerData.Sessions,
		random_salt = playerData.Sessions,
	}

	return initAnnotations
end

local HashLib_hmac = HashLib.hmac
local HashLib_base64_encode = HashLib.base64_encode

local function encode(payload, secretKey)
	--Validate
	if not secretKey then
		Logger:warning("Error encoding, invalid SecretKey")
		return
	end

	--Encode
	local payloadHmac = HashLib_hmac(HashLib.sha256, RunService:IsStudio() and "16813a12f718bc5c620f56944e1abc3ea13ccbac" or secretKey, payload, true)
	return HashLib_base64_encode(payloadHmac)
end

local function processRequestResponse(response, requestId)
	local statusCode = response.StatusCode
	local body = response.Body

	if not body or #body == 0 then
		Logger:debug(requestId .. " request. failed. Might be no connection. Status code: " .. tostring(statusCode))
		return HttpApi.EGAHTTPApiResponse.NoResponse
	end

	if statusCode == 200 then
		return HttpApi.EGAHTTPApiResponse.Ok
	elseif statusCode == 201 then
		return HttpApi.EGAHTTPApiResponse.Created
	elseif statusCode == 0 or statusCode == 401 then
		Logger:debug(requestId .. " request. 401 - Unauthorized.")
		return HttpApi.EGAHTTPApiResponse.Unauthorized
	elseif statusCode == 400 then
		Logger:debug(requestId .. " request. 400 - Bad Request.")
		return HttpApi.EGAHTTPApiResponse.BadRequest
	elseif statusCode == 500 then
		Logger:debug(requestId .. " request. 500 - Internal Server Error.")
		return HttpApi.EGAHTTPApiResponse.InternalServerError
	else
		return HttpApi.EGAHTTPApiResponse.UnknownResponseCode
	end
end

function HttpApi:initRequest(gameKey, secretKey, build, playerData, playerId)
	local url = remoteConfigsBaseUrl .. "/" .. self.initializeUrlPath .. "?game_key=" .. gameKey .. "&interval_seconds=0&configs_hash=" .. (playerData.ConfigsHash or "")
	if RunService:IsStudio() then
		url = baseUrl .. "/5c6bcb5402204249437fb5a7a80a4959/" .. self.initializeUrlPath
	end

	Logger:debug("Sending 'init' URL: " .. url)

	local payload = HttpService:JSONEncode(getInitAnnotations(build, playerData, playerId))
	payload = string.gsub(payload, "\"country_code\":\"unknown\"", "\"country_code\":null")
	local authorization = encode(payload, secretKey)

	Logger:debug("init payload: " .. payload)

	local _, responseOrError = HttpPromise.promiseRequest({
		Body = payload,
		Headers = {
			Authorization = authorization,
			["Content-Type"] = "application/json",
		},

		Method = "POST",
		Url = url,
	}):andThen(function(response)
		Logger:debug("init request content: " .. response.Body)
		local requestResponseEnum = processRequestResponse(response, "Init")

		-- if not 200 result
		if requestResponseEnum ~= self.EGAHTTPApiResponse.Ok and requestResponseEnum ~= self.EGAHTTPApiResponse.Created and requestResponseEnum ~= self.EGAHTTPApiResponse.BadRequest then
			Logger:debug("Failed Init Call. URL: " .. url .. ", JSONString: " .. payload .. ", Authorization: " .. authorization)
			return {
				body = nil,
				statusCode = requestResponseEnum,
			}
		end

		return HttpPromise.promiseJsonDecode(response.Body):andThen(function(responseBody)
			-- print reason if bad request
			if requestResponseEnum == self.EGAHTTPApiResponse.BadRequest then
				Logger:debug("Failed Init Call. Bad request. Response: " .. response.Body)
				return {
					body = nil,
					statusCode = requestResponseEnum,
				}
			end

			-- validate Init call values
			local validatedInitValues = Validation.validateAndCleanInitRequestResponse(responseBody, requestResponseEnum == self.EGAHTTPApiResponse.Created)
			if not validatedInitValues then
				return {
					body = nil,
					statusCode = self.EGAHTTPApiResponse.BadResponse,
				}
			end

			-- all ok
			return {
				body = responseBody,
				statusCode = requestResponseEnum,
			}
		end):catch(function(decodeError)
			Logger:debug("Failed Init Call. Json decoding failed: " .. tostring(decodeError))
			return {
				body = nil,
				statusCode = self.EGAHTTPApiResponse.JsonDecodeFailed,
			}
		end)
	end):catch(function(requestError)
		Logger:debug("Failed Init Call. error: " .. tostring(requestError))
		return {
			body = nil,
			statusCode = self.EGAHTTPApiResponse.UnknownResponseCode,
		}
	end):await()

	return responseOrError
end

function HttpApi:oldInitRequest(gameKey, secretKey, build, playerData, playerId)
	local url = remoteConfigsBaseUrl .. "/" .. self.initializeUrlPath .. "?game_key=" .. gameKey .. "&interval_seconds=0&configs_hash=" .. (playerData.ConfigsHash or "")
	if RunService:IsStudio() then
		url = baseUrl .. "/5c6bcb5402204249437fb5a7a80a4959/" .. self.initializeUrlPath
	end

	Logger:debug("Sending 'init' URL: " .. url)

	local payload = HttpService:JSONEncode(getInitAnnotations(build, playerData, playerId))
	payload = string.gsub(payload, "\"country_code\":\"unknown\"", "\"country_code\":null")
	local authorization = encode(payload, secretKey)

	Logger:debug("init payload: " .. payload)

	local response
	local success, requestError = pcall(function()
		response = HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = {
				Authorization = authorization,
				["Content-Type"] = "application/json",
			},

			Body = payload,
		})
	end)

	if not success then
		Logger:debug("Failed Init Call. error: " .. requestError)
		return {
			body = nil,
			statusCode = self.EGAHTTPApiResponse.UnknownResponseCode,
		}
	end

	Logger:debug("init request content: " .. response.Body)
	local requestResponseEnum = processRequestResponse(response, "Init")

	-- if not 200 result
	if requestResponseEnum ~= self.EGAHTTPApiResponse.Ok and requestResponseEnum ~= self.EGAHTTPApiResponse.Created and requestResponseEnum ~= self.EGAHTTPApiResponse.BadRequest then
		Logger:debug("Failed Init Call. URL: " .. url .. ", JSONString: " .. payload .. ", Authorization: " .. authorization)
		return {
			body = nil,
			statusCode = requestResponseEnum,
		}
	end

	--Response
	local responseBody
	success = pcall(function()
		responseBody = HttpService:JSONDecode(response.Body)
	end)

	if not success then
		Logger:debug("Failed Init Call. Json decoding failed: " .. requestError)
		return {
			body = nil,
			statusCode = self.EGAHTTPApiResponse.JsonDecodeFailed,
		}
	end

	-- print reason if bad request
	if requestResponseEnum == self.EGAHTTPApiResponse.BadRequest then
		Logger:debug("Failed Init Call. Bad request. Response: " .. response.Body)
		return {
			body = nil,
			statusCode = requestResponseEnum,
		}
	end

	-- validate Init call values
	local validatedInitValues = Validation.validateAndCleanInitRequestResponse(responseBody, requestResponseEnum == self.EGAHTTPApiResponse.Created)
	if not validatedInitValues then
		return {
			body = nil,
			statusCode = self.EGAHTTPApiResponse.BadResponse,
		}
	end

	-- all ok
	return {
		body = responseBody,
		statusCode = requestResponseEnum,
	}
end

function HttpApi:sendEventsInArray(gameKey, secretKey, eventArray)
	if not eventArray or #eventArray == 0 then
		Logger:debug("sendEventsInArray called with missing eventArray")
		return
	end

	-- Generate URL
	local url = baseUrl .. "/" .. gameKey .. "/" .. self.eventsUrlPath
	if RunService:IsStudio() then
		url = baseUrl .. "/5c6bcb5402204249437fb5a7a80a4959/" .. self.eventsUrlPath
	end

	Logger:debug("Sending 'events' URL: " .. url)

	-- make JSON string from data
	local payload = HttpService:JSONEncode(eventArray)
	payload = string.gsub(payload, "\"country_code\":\"unknown\"", "\"country_code\":null")
	local authorization = encode(payload, secretKey)

	local _, responseOrError = HttpPromise.promiseRequest({
		Body = payload,
		Headers = {
			Authorization = authorization,
			["Content-Type"] = "application/json",
		},

		Method = "POST",
		Url = url,
	}):andThen(function(response)
		Logger:debug("body: " .. response.Body)
		local requestResponseEnum = processRequestResponse(response, "Events")

		-- if not 200 result
		if requestResponseEnum ~= self.EGAHTTPApiResponse.Ok and requestResponseEnum ~= self.EGAHTTPApiResponse.Created and requestResponseEnum ~= self.EGAHTTPApiResponse.BadRequest then
			Logger:debug("Failed Events Call. URL: " .. url .. ", JSONString: " .. payload .. ", Authorization: " .. authorization)
			return {
				statusCode = requestResponseEnum,
				body = nil,
			}
		end

		return HttpPromise.promiseJsonDecode(response.Body):andThen(function(responseBody)
			if requestResponseEnum == self.EGAHTTPApiResponse.BadRequest then
				Logger:debug("Failed Events Call. Bad request. Response: " .. response.Body)
				return {
					body = nil,
					statusCode = requestResponseEnum,
				}
			end

			-- all ok
			return {
				body = responseBody,
				statusCode = self.EGAHTTPApiResponse.Ok,
			}
		end):catch(function(decodeError)
			Logger:debug("Failed Events Call. Json decoding failed: " .. tostring(decodeError))
			return {
				statusCode = self.EGAHTTPApiResponse.JsonDecodeFailed,
				body = nil,
			}
		end)
	end):catch(function(requestError)
		Logger:debug("Failed Events Call. error: " .. tostring(requestError))
		return {
			body = nil,
			statusCode = self.EGAHTTPApiResponse.UnknownResponseCode,
		}
	end):await()

	return responseOrError
end

function HttpApi:oldSendEventsInArray(gameKey, secretKey, eventArray)
	if not eventArray or #eventArray == 0 then
		Logger:debug("sendEventsInArray called with missing eventArray")
		return
	end

	-- Generate URL
	local url = baseUrl .. "/" .. gameKey .. "/" .. self.eventsUrlPath
	if RunService:IsStudio() then
		url = baseUrl .. "/5c6bcb5402204249437fb5a7a80a4959/" .. self.eventsUrlPath
	end

	Logger:debug("Sending 'events' URL: " .. url)

	-- make JSON string from data
	local payload = HttpService:JSONEncode(eventArray)
	payload = string.gsub(payload, "\"country_code\":\"unknown\"", "\"country_code\":null")
	local authorization = encode(payload, secretKey)

	local response
	local success, requestError = pcall(function()
		response = HttpService:RequestAsync({
			Body = payload,
			Headers = {
				Authorization = authorization,
				["Content-Type"] = "application/json",
			},

			Method = "POST",
			Url = url,
		})
	end)

	if not success then
		Logger:debug("Failed Events Call. error: " .. requestError)
		return {
			body = nil,
			statusCode = self.EGAHTTPApiResponse.UnknownResponseCode,
		}
	end

	Logger:debug("body: " .. response.Body)
	local requestResponseEnum = processRequestResponse(response, "Events")

	-- if not 200 result
	if requestResponseEnum ~= self.EGAHTTPApiResponse.Ok and requestResponseEnum ~= self.EGAHTTPApiResponse.Created and requestResponseEnum ~= self.EGAHTTPApiResponse.BadRequest then
		Logger:debug("Failed Events Call. URL: " .. url .. ", JSONString: " .. payload .. ", Authorization: " .. authorization)
		return {
			body = nil,
			statusCode = requestResponseEnum,
		}
	end

	local responseBody
	pcall(function()
		responseBody = HttpService:JSONDecode(response.Body)
	end)

	if not responseBody then
		Logger:debug("Failed Events Call. Json decoding failed")
		return {
			body = nil,
			statusCode = self.EGAHTTPApiResponse.JsonDecodeFailed,
		}
	end

	-- print reason if bad request
	if requestResponseEnum == self.EGAHTTPApiResponse.BadRequest then
		Logger:debug("Failed Events Call. Bad request. Response: " .. response.Body)
		return {
			body = nil,
			statusCode = requestResponseEnum,
		}
	end

	-- all ok
	return {
		body = responseBody,
		statusCode = self.EGAHTTPApiResponse.Ok,
	}
end

return HttpApi
