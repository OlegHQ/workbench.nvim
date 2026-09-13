pcall(vim.api.nvim_create_user_command, "Workbench", function(command)
  require("workbench").command(command.args)
end, {
  nargs = "?",
  desc = "Inspect or explicitly control the workspace workbench",
})
