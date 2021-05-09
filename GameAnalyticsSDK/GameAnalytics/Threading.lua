local RunService = game:GetService("RunService")
local Logger = require(script.Parent.Logger)
local Scheduler = require(script.Parent.Scheduler)

local Threading = {
	_canSafelyClose = true,
	_endThread = false,
	_isRunning = false,
	_blocks = {},
	_scheduledBlock = nil,
	_hasScheduledBlockRun = true,
}

local Scheduler_Spawn = Scheduler.Spawn
local Scheduler_Wait = Scheduler.Wait
local TimeFunction = Scheduler.TimeFunction

local function getScheduledBlock()
	local now = TimeFunction()

	if not Threading._hasScheduledBlockRun and Threading._scheduledBlock ~= nil and Threading._scheduledBlock.deadline <= now then
		Threading._hasScheduledBlockRun = true
		return Threading._scheduledBlock
	else
		return nil
	end
end

local function run()
	Scheduler_Spawn(function()
		Logger:debug("Starting GA thread")

		while not Threading._endThread do
			Threading._canSafelyClose = false

			if #Threading._blocks ~= 0 then
				for _, block in ipairs(Threading._blocks) do
					local success, callError = pcall(block.block)
					if not success then
						Logger:error(callError)
					end
				end

				Threading._blocks = {}
			end

			local timedBlock = getScheduledBlock()
			if timedBlock ~= nil then
				local success, callError = pcall(timedBlock.block)
				if not success then
					Logger:error(callError)
				end
			end

			Threading._canSafelyClose = true
			Scheduler_Wait(1)
		end

		Logger:debug("GA thread stopped")
	end)

	--Safely Close
	game:BindToClose(function()
		-- waiting bug fix to work inside studio
		if RunService:IsStudio() then
			return
		end

		--Give game.Players.PlayerRemoving time to to its thang
		Scheduler_Wait(1)

		--Delay
		if not Threading._canSafelyClose then
			repeat
				Scheduler_Wait(0.03)
			until Threading._canSafelyClose
		end

		Scheduler_Wait(3)
	end)
end

function Threading:scheduleTimer(interval, callback)
	if self._endThread then
		return
	end

	if not self._isRunning then
		self._isRunning = true
		run()
	end

	local timedBlock = {
		block = callback,
		deadline = TimeFunction() + interval,
	}

	if self._hasScheduledBlockRun then
		self._scheduledBlock = timedBlock
		self._hasScheduledBlockRun = false
	end
end

function Threading:performTaskOnGAThread(callback)
	if self._endThread then
		return
	end

	if not self._isRunning then
		self._isRunning = true
		run()
	end

	table.insert(self._blocks, {block = callback})
end

function Threading:stopThread()
	self._endThread = true
end

return Threading
