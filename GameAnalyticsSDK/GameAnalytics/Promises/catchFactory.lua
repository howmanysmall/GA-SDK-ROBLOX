local function catchFactory(functionName: string)
	return function(resultingError)
		warn(string.format("Error in function %s: %s", functionName, tostring(resultingError)))
	end
end

return catchFactory
