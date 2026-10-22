local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, lines = H.check, H.lines

H.run(function()
  local rg = require("agentic_review")
  rg.setup({ agent = "fake", auto_tour = false, adapters = { fake = H.fake_agent("[high] src/cart.lua:17: boom") } })
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  local files, _, head, agent = unpack(H.review_wins())
  rg.action("review")
  H.wait_answers(vim.api.nvim_win_get_buf(agent), 1)
  local pns = vim.api.nvim_get_namespaces().agentic_review_pane

  local function picker()
    for _, w in ipairs(H.floats()) do
      local title = vim.api.nvim_win_get_config(w).title
      if title and title[1][1] == " Go to file " then
        return w, vim.api.nvim_win_get_buf(w)
      end
    end
  end
  local function selected_line()
    local _, buf = picker()
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, pns, 0, -1, { details = true })) do
      if m[4].line_hl_group == "PmenuSel" then
        return lines(buf)[m[2] + 1]
      end
    end
  end
  local function right_text(fragment)
    local _, buf = picker()
    for i, l in ipairs(lines(buf)) do
      if l:find(fragment, 1, true) then
        local out = {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, pns, { i - 1, 0 }, { i - 1, -1 }, { details = true })) do
          if m[4].virt_text_pos == "right_align" then
            for _, chunk in ipairs(m[4].virt_text) do
              out[#out + 1] = chunk[1]
            end
          end
        end
        return table.concat(out)
      end
    end
  end

  rg.files()
  local win, buf = picker()
  check("picker opened", win ~= nil and vim.api.nvim_get_current_win() == win)
  local tree = buf and vim.list_slice(lines(buf), 3) or {}
  check(
    "tree by directory",
    vim.deep_equal(tree, {
      "docs/",
      "└─ ● R README.md",
      "./",
      "└─ · A logo.png",
      "src/",
      "├─ · M cart.lua",
      "├─ · A discount.lua",
      "└─ · D util.lua",
    }),
    tree
  )
  check("starts on the current file", selected_line() == "└─ ● R README.md", selected_line())
  check("finding badge and stats", right_text("cart.lua") == " 1 high   +3 -2", right_text("cart.lua"))

  vim.api.nvim_feedkeys("jj", "x", false)
  check("j skips directory rows", selected_line() == "├─ · M cart.lua", selected_line())
  vim.api.nvim_feedkeys("v", "x", false)
  check("v marks viewed", selected_line() == "├─ ✓ M cart.lua", selected_line())
  check("files panel follows", lines(vim.api.nvim_win_get_buf(files))[2]:find("^1/5 viewed") ~= nil)

  -- / opens a search line over the first row and filters as it changes.
  vim.api.nvim_feedkeys("/", "x", false)
  local prompt = vim.api.nvim_get_current_win()
  check("search line over the list", prompt ~= win and vim.api.nvim_win_get_config(prompt).win == win)
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(prompt), 0, -1, false, { "disc" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = vim.api.nvim_win_get_buf(prompt) })
  tree = vim.list_slice(lines(buf), 3)
  check("filtered", vim.deep_equal(tree, { "src/", "└─ · A discount.lua" }), tree)
  check("filter count", right_text("") == "1 of 5", right_text(""))
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  check("enter opens the match", #H.floats() == 0, #H.floats())
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(head))
  check("head shows it", name:find("src/discount.lua$") ~= nil, name)

  -- Leaving the picker for another window closes it.
  vim.cmd("ReviewFiles")
  check(":ReviewFiles opens it", picker() ~= nil)
  vim.api.nvim_set_current_win(head)
  vim.wait(500, function()
    return picker() == nil
  end)
  check("closes when left", picker() == nil)

  vim.api.nvim_set_current_win(files)
  vim.api.nvim_feedkeys("f", "x", false)
  check("f in the files panel", picker() ~= nil)
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
  check("esc closes", picker() == nil)
end)
