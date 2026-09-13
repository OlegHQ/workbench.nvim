local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child

return MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = MiniTest.new_child_neovim()
      child.start({}, { nvim_executable = assert(vim.env.NVIM_TEST_BINARY) })
    end,
    post_case = function()
      if child then
        pcall(child.stop)
        child = nil
      end
    end,
  },
}, {
  ["mini.test child accepts user input and exposes a screen snapshot"] = function()
    child.api.nvim_buf_set_lines(0, 0, -1, true, { "Harness screen probe" })
    child.type_keys("gg")
    local screenshot = child.get_screenshot()
    expect.no_equality(screenshot, nil)
    expect.equality(table.concat(screenshot.text[1]), "Harness screen probe" .. string.rep(" ", 80 - #"Harness screen probe"))
    expect.equality(child.api.nvim_get_current_line(), "Harness screen probe")
  end,
})
