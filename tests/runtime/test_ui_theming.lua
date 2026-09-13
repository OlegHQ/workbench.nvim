local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

return MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = MiniTest.new_child_neovim()
      child.start({}, { nvim_executable = assert(vim.env.NVIM_TEST_BINARY) })
      child.lua("local root = ...; vim.opt.runtimepath:prepend(root)", { root })
    end,
    post_case = function()
      if child then pcall(child.stop); child = nil end
    end,
  },
}, {
  ["view installs semantic color links without hardcoded colors"] = function()
    local links = child.lua([[
      local Scope = require('workbench.core.scope')
      local View = require('workbench.ui.view')
      local scope = Scope.new('theming-test')
      local view = assert(View.new({ id='semantic-links', scope=scope, model={status='ready', items={}} }))
      local expected = {
        WorkbenchNormal='Normal', WorkbenchMuted='Comment', WorkbenchBorder='WinSeparator',
        WorkbenchDirectory='Directory', WorkbenchMatch='Search', WorkbenchError='ErrorMsg',
        WorkbenchWarning='DiagnosticWarn', WorkbenchInfo='DiagnosticInfo',
        WorkbenchGitAdded='DiffAdd', WorkbenchGitModified='DiffChange', WorkbenchGitDeleted='DiffDelete',
        WorkbenchDisabled='Comment', WorkbenchLoading='MoreMsg',
        WorkbenchTitle='Title', WorkbenchItem='Normal', WorkbenchSelection='CursorLine',
        WorkbenchEnclosingSymbol='Underlined', WorkbenchHelp='Comment', WorkbenchDetail='NonText',
      }
      local actual = {}
      for name, target in pairs(expected) do
        local definition = vim.api.nvim_get_hl(0, { name=name, link=true })
        actual[name] = { target=definition.link, matched=definition.link == target,
          hardcoded=definition.fg ~= nil or definition.bg ~= nil }
      end
      scope:dispose()
      return actual
    ]])
    for name, link in pairs(links) do
      expect.equality(link.matched, true, name .. " link target")
      expect.equality(link.hardcoded, false, name .. " remains color-free")
    end
  end,
})
