local h = require('tests.helpers')

local backend = require('smart-splits-backend-rex')
local protocol_tests = require('smart-splits.protocol_tests')

---@param title string
---@param enter fun()
local function conformance(title, enter)
  describe(title, function()
    before_each(enter)
    after_each(h.restore)

    for _, test in ipairs(protocol_tests.tests(backend)) do
      it(test.name, function()
        local result = test.fn()
        assert.is_true(result, tostring(result))
      end)
    end
  end)
end

conformance('backend protocol conformance outside Rex', function() end)

conformance('backend protocol conformance inside a Rex pane', function()
  h.rex('nested-4pane', h.ids.A)
end)

conformance('backend protocol conformance with Rex unreachable', function()
  h.rex('nested-4pane', h.ids.A, { result = { code = 1, signal = 0, stdout = '', stderr = 'Error: no server' } })
end)
