local MiniTest = require("mini.test")
local cases = MiniTest.collect()
if #cases == 0 then
  io.stderr:write("mini.test collected no cases\n")
  vim.cmd("cquit 2")
  return
end

local reporter = MiniTest.gen_reporter.stdout()
local finish = reporter.finish
reporter.finish = function()
  finish()
  for _, case in ipairs(MiniTest.current.all_cases or {}) do
    if case.exec and #case.exec.fails > 0 then
      vim.cmd("cquit 1")
      return
    end
  end
  vim.cmd("qa!")
end

MiniTest.execute(cases, { reporter = reporter })
