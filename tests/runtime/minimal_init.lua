local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h:h")
local deps = assert(vim.env.WORKBENCH_TEST_DEPS, "WORKBENCH_TEST_DEPS is required")

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(deps .. "/mini.test")
vim.opt.runtimepath:append(root .. "/tests")

require("mini.test").setup({
  collect = {
    find_files = function()
      if vim.env.WORKBENCH_TEST_FILE then return { vim.env.WORKBENCH_TEST_FILE } end
      return vim.fn.globpath(root .. "/tests/runtime", "test_*.lua", false, true)
    end,
  },
  execute = { reporter = require("mini.test").gen_reporter.stdout() },
})
