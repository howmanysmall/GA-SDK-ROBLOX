local function lockTable(tab)
	return setmetatable({}, {
		__index = tab,
		__newindex = function(self, key, value)
			error("Attempt to modify read-only table: " .. self .. ", key=" .. key .. ", value=" .. value)
		end,

		__metatable = false,
	})
end

return lockTable
