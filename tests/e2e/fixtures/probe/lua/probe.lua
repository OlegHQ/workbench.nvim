local M = {}

function M.setup()
  vim.o.mouse = "a"

  vim.api.nvim_create_user_command("WorkbenchProbe", function()
    local origin_win = vim.api.nvim_get_current_win()
    local origin_buf = vim.api.nvim_get_current_buf()
    vim.cmd("botright 5new")

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    local wrong_render = vim.env.WORKBENCH_E2E_MODE == "wrong-render"
    local lines = wrong_render
        and { "Workbench E2E broken render", "mouse-target" }
      or { "Workbench E2E ready", "mouse-target" }

    vim.api.nvim_buf_set_name(buf, "workbench://probe")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false

    vim.keymap.set("n", "q", function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end, { buffer = buf, desc = "Close E2E probe" })

    if vim.env.WORKBENCH_E2E_MODE == "wrong-focus" then
      vim.api.nvim_set_current_win(origin_win)
      vim.api.nvim_set_current_buf(origin_buf)
    end
  end, {})
end

return M
