local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, lines = H.check, H.lines

local function read(path)
  local fh = io.open(path, "rb")
  local data = fh and fh:read("*a")
  if fh then
    fh:close()
  end
  return data
end

H.run(function()
  -- logo.png was committed as a stub; the working tree gets a real 3x2 PNG header, so the review sees it modified.
  local stub = read(H.repo .. "/logo.png")
  local png = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\3\0\0\0\2\8\6\0\0\0" .. ("\0"):rep(9)
  local fh = assert(io.open(H.repo .. "/logo.png", "wb"))
  fh:write(png)
  fh:close()

  local rg = require("agentic_review")
  rg.setup({ agent = "fake", auto_tour = false, adapters = { fake = H.fake_agent("ok") } })
  rg.open("HEAD")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  local files, base, head = unpack(H.review_wins())

  local function open(name)
    vim.api.nvim_set_current_win(files)
    for i, l in ipairs(lines(vim.api.nvim_win_get_buf(files))) do
      if l:find(name, 1, true) then
        vim.api.nvim_win_set_cursor(files, { i, 0 })
      end
    end
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  end
  local function shown(win)
    return lines(vim.api.nvim_win_get_buf(win))
  end

  -- Without snacks.nvim each side gets a card with the format, size and dimensions.
  open(" logo.png")
  check(
    "base card",
    vim.deep_equal(shown(base), { "PNG · 10 B", "", "gx opens it in your image viewer" }),
    shown(base)
  )
  check("head card", shown(head)[1] == ("PNG · 3×2 · %d B"):format(#png), shown(head))
  check("no diff mode on images", not vim.wo[base].diff and not vim.wo[head].diff)

  local opened
  vim.ui.open = function(path)
    opened = path
  end
  vim.api.nvim_set_current_win(base)
  vim.api.nvim_feedkeys("gx", "x", false)
  check("gx opens the base revision", opened and opened:find("%.png$") ~= nil and read(opened) == stub, opened)

  -- With snacks.nvim each side shows the image itself, and code windows get their options back afterwards.
  local attached = {}
  _G.Snacks = {
    image = {
      config = { wo = { number = false } },
      supports_terminal = function()
        return true
      end,
      buf = {
        attach = function(buf, opts)
          attached[#attached + 1] = opts.src
          for _, w in ipairs(vim.fn.win_findbuf(buf)) do
            vim.wo[w].number = false
          end
        end,
      },
    },
  }
  open(" cart.lua")
  vim.wo[head].number = true
  open(" logo.png")
  check("snacks gets both sides", #attached == 2, attached)
  check("base image is the old revision", attached[1] and read(attached[1]) == stub)
  check("head image is the working tree file", attached[2] == H.repo .. "/logo.png", attached[2])
  check("snacks owns the window", not vim.wo[head].number)
  open(" cart.lua")
  check("code gets its window options back", vim.wo[head].number and vim.wo[base].diff)

  rg.config.images = false
  open(" logo.png")
  check("images off", vim.deep_equal(shown(base), { "(binary file)" }), shown(base))
end)
