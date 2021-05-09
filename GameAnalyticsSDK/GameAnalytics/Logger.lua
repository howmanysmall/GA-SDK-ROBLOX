local RunService = game:GetService("RunService")
local Scheduler = require(script.Parent.Scheduler)
local Scheduler_FastSpawn = Scheduler.FastSpawn

local Logger = {
	_infoLogEnabled = false,
	_infoLogAdvancedEnabled = false,
	_debugEnabled = RunService:IsStudio(),
}

function Logger:setDebugLog(enabled)
	self._debugEnabled = enabled
end

function Logger:setInfoLog(enabled)
	self._infoLogEnabled = enabled
end

function Logger:setVerboseLog(enabled)
	self._infoLogAdvancedEnabled = enabled
end

function Logger:information(format)
	if not self._infoLogEnabled then
		return
	end

	print("Info/GameAnalytics: " .. format)
end

function Logger:warning(format)
	warn("Warning/GameAnalytics: " .. format)
end

function Logger:error(format)
	Scheduler_FastSpawn(error, "Error/GameAnalytics: " .. format, 0)
end

function Logger:debug(format)
	if not self._debugEnabled then
		return
	end

	print("Debug/GameAnalytics: " .. format)
end

function Logger:verboseInformation(format)
	if not self._infoLogAdvancedEnabled then
		return
	end

	print("Verbose/GameAnalytics: " .. format)
end

return Logger
