local MiniTest = require("mini.test")

return MiniTest.new_set({}, {
  ["intentional failure for runner exit-status verification"] = function()
    error("intentional failure probe")
  end,
})
