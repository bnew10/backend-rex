describe('backend protocol conformance', function()
  local backend = require('smart-splits-backend-rex')
  for _, test in ipairs(require('smart-splits.protocol_tests').tests(backend)) do
    it(test.name, function()
      local result = test.fn()
      assert.is_true(result, tostring(result))
    end)
  end
end)
