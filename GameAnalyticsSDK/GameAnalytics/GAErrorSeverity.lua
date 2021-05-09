local lockTable = require(script.Parent.lockTable)

return lockTable({
	debug = "debug",
	info = "info",
	warning = "warning",
	error = "error",
	critical = "critical",
})
