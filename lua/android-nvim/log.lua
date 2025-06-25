local M = {}

local levels = vim.log.levels

local function notify(msg, level)
    vim.notify(string.format("[android-nvim] %s", msg), level)
end

M.info = function(msg)
    notify(msg, levels.INFO)
end
M.warn = function(msg)
    notify(msg, levels.WARN)
end
M.error = function(msg)
    notify(msg, levels.ERROR)
end

return M
