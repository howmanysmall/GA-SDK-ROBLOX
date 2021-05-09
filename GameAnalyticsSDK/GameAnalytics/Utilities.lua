local Utilities = {}

function Utilities.isStringNullOrEmpty(string)
	return not string or #string == 0
end

function Utilities.stringArrayContainsString(array, search)
	if #array == 0 then
		return false
	end

	for _, searchString in ipairs(array) do
		if searchString == search then
			return true
		end
	end

	return false
end

return Utilities
