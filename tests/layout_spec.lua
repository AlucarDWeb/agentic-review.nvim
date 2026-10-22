local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, lines = H.check, H.lines

H.run(function()
  local rg = require("agentic_review")
  rg.setup({ agent = "fake", auto_tour = false, adapters = { fake = H.fake_agent("ok") } })
  vim.o.columns, vim.o.lines = 132, 38
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  local files, agent, base, head
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name == "review://files" then
      files = win
    elseif name == "review://agent" then
      agent = win
    elseif base then
      head = win
    else
      base = win
    end
  end
  local width, height = vim.api.nvim_win_get_width, vim.api.nvim_win_get_height

  local function open(name)
    vim.api.nvim_set_current_win(files)
    for i, l in ipairs(lines(vim.api.nvim_win_get_buf(files))) do
      if l:find(name, 1, true) then
        vim.api.nvim_win_set_cursor(files, { i, 0 })
      end
    end
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  end

  local function resize(columns, rows)
    vim.o.columns, vim.o.lines = columns, rows
    vim.api.nvim_exec_autocmds("VimResized", {})
  end

  local stacked = {
    "col",
    { { "row", { { "leaf", base }, { "leaf", head } } }, { "row", { { "leaf", files }, { "leaf", agent } } } },
  }
  local side_by_side = { "row", { { "leaf", files }, { "leaf", base }, { "leaf", head }, { "leaf", agent } } }

  -- A narrow screen gives the diff the full width and puts the files and agent panes under it.
  open(" cart.lua")
  check("narrow: panels under diff", vim.deep_equal(vim.fn.winlayout(), stacked), vim.fn.winlayout())
  check("narrow: files width", width(files) == 34, width(files))
  check("narrow: halves", width(base) >= 65 and math.abs(width(base) - width(head)) <= 1, { width(base), width(head) })
  check("narrow: bottom height", height(agent) == math.floor(38 * 0.33) and height(files) == height(agent))
  check(
    "narrow: fixed heights",
    vim.wo[agent].winfixheight and vim.wo[files].winfixheight and not vim.wo[agent].winfixwidth
  )

  open(" discount.lua")
  check("added: head takes base side", width(base) == 1 and width(head) >= 130, { width(base), width(head) })

  -- At 172 columns four columns would leave each diff pane 39 wide, under min_diff_width.
  resize(172, 50)
  check("172 columns stack", vim.deep_equal(vim.fn.winlayout(), stacked), vim.fn.winlayout())

  -- Widening the screen goes back to four columns.
  resize(300, 50)
  check("wide: four columns", vim.deep_equal(vim.fn.winlayout(), side_by_side), vim.fn.winlayout())
  check("wide: agent width", width(agent) == math.floor(300 * 0.33), width(agent))
  check("wide: added still collapsed", width(base) == 1, { width(base), width(head) })

  open(" util.lua")
  check("deleted: base takes head side", width(head) == 1 and width(base) > 100, { width(base), width(head) })

  open(" cart.lua")
  check("modified: halves", math.abs(width(base) - width(head)) <= 1, { width(base), width(head) })

  resize(132, 38)
  check("narrow again", vim.deep_equal(vim.fn.winlayout(), stacked), vim.fn.winlayout())

  -- A resize seen from another tab is applied when the review tab is entered again.
  vim.cmd("tabprevious")
  resize(300, 50)
  vim.cmd("tabnext")
  check("resize from another tab", vim.deep_equal(vim.fn.winlayout(), side_by_side), vim.fn.winlayout())
end)
