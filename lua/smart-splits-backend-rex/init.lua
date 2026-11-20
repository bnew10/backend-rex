---@module 'smart-splits.backend'

---@type SmartSplitsBackend
local M = {
  name = 'smart-splits-backend-rex',
  protocol_version = '3.0.0',
}

function M.detect()
  return false
end

function M.move()
  return false
end

return M
