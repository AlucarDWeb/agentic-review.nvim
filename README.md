# agentic-review.nvim

Code review in Neovim with a read-only coding agent next to the diff, on a branch or a GitHub pull request. Details are in `:help agentic-review.txt`.

## Requirements

| Tool | Needed for |
| --- | --- |
| Neovim 0.10 or newer | |
| git | |
| `claude` ([Claude Code](https://github.com/anthropics/claude-code)) or `pi` ([pi](https://github.com/earendil-works/pi)), logged in | The agent, unless you write your own adapter |
| [`gh`](https://cli.github.com), logged in | Pull requests and GitHub comments |
| [snacks.nvim](https://github.com/folke/snacks.nvim) (optional) | Image previews |
| [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) (optional) | Rendered answers |

`:checkhealth agentic_review` lists what is missing. With lazy.nvim, run `:Lazy load agentic-review.nvim` first.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim), with suggested keymaps (the plugin sets none):

```lua
{
  "AlucarDWeb/agentic-review.nvim",
  version = "*",
  cmd = { "Review", "ReviewClose", "ReviewCancel", "ReviewRefs", "ReviewAsk", "ReviewComment", "ReviewCommentAll", "ReviewThread", "ReviewSubmit", "ReviewFiles" },
  keys = {
    { "<leader>R", "", desc = "+review" },
    { "<leader>Rr", "<cmd>Review<cr>", desc = "Review branch vs base" },
    {
      "<leader>RP",
      function()
        vim.ui.input({ prompt = "PR number: " }, function(n)
          if n and n ~= "" then
            require("agentic_review").open(n)
          end
        end)
      end,
      desc = "Review a PR",
    },
    { "<leader>Re", function() require("agentic_review").action("explain") end, mode = { "n", "x" }, desc = "Explain" },
    { "<leader>Rx", function() require("agentic_review").action("explore") end, mode = { "n", "x" }, desc = "Explore around" },
    { "<leader>Rd", function() require("agentic_review").action("deep") end, mode = { "n", "x" }, desc = "Deep dive" },
    { "<leader>Ra", function() require("agentic_review").action("ask") end, mode = { "n", "x" }, desc = "Ask" },
    { "<leader>RR", function() require("agentic_review").action("review") end, desc = "Review the whole change" },
    { "<leader>Rf", function() require("agentic_review").answer() end, desc = "Show last answer" },
    { "<leader>Rg", function() require("agentic_review").comment() end, mode = { "n", "x" }, desc = "Comment on GitHub" },
    { "<leader>RG", "<cmd>ReviewCommentAll<cr>", desc = "Send every finding to GitHub" },
    { "<leader>Rk", "<cmd>ReviewThread<cr>", desc = "GitHub comments on the line" },
    { "<leader>RS", "<cmd>ReviewSubmit<cr>", desc = "Submit GitHub review" },
    { "<leader>Rn", function() require("agentic_review").next(1) end, desc = "Next file" },
    { "<leader>RN", function() require("agentic_review").next(-1) end, desc = "Previous file" },
    { "<leader>Rt", function() require("agentic_review").files() end, desc = "Go to a changed file" },
    { "<leader>Rv", function() require("agentic_review").toggle_viewed() end, desc = "Mark viewed, go to next" },
    { "<leader>Rl", "<cmd>ReviewRefs<cr>", desc = "Answer refs to quickfix" },
    { "<leader>Rc", "<cmd>ReviewCancel<cr>", desc = "Cancel agent answer" },
    { "<leader>Rq", "<cmd>ReviewClose<cr>", desc = "Close review" },
  },
  opts = {},
}
```

Neovim 0.12, built-in `vim.pack`:

```lua
vim.pack.add({ { src = "https://github.com/AlucarDWeb/agentic-review.nvim", version = vim.version.range("*") } })
require("agentic_review").setup({})
```

Neovim 0.10 and 0.11, a package directory, then `require("agentic_review").setup({})` in your `init.lua`:

```sh
git clone --depth 1 --branch v0.1.1 https://github.com/AlucarDWeb/agentic-review.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/agentic-review.nvim
```

## Commands

| Command | What it does |
| --- | --- |
| `:Review` | Review the current branch against its merge-base with `origin/HEAD`, uncommitted changes included |
| `:Review <ref>` | Review against another base, such as `origin/develop`, or `HEAD` for uncommitted changes only |
| `:Review #123` | Review a pull request, fetched through `gh` |
| `:Review!` | Any of the above, ignoring the saved session |
| `:ReviewAsk [question]` | Ask the agent about the range |
| `:ReviewFiles` | Go to a changed file |
| `:ReviewComment` | Comment on the line or range, in your pending GitHub review |
| `:ReviewCommentAll` | Add every finding not yet on GitHub to your pending review |
| `:ReviewThread` | Read the open GitHub threads on the line, and reply to them |
| `:ReviewSubmit` | Submit your review as Comment, Approve or Request changes |
| `:ReviewRefs` | Send every `path:line` in the last answer to the quickfix list |
| `:ReviewCancel` | Cancel the running answer |
| `:ReviewClose` | Close the review |

## Agent actions

`require("agentic_review").action(name)` works on the hunk under the cursor, the visual selection, or the whole file from the files panel. In the review tab the answer goes to the agent pane, elsewhere to a float under the code.

| Action | What the agent does |
| --- | --- |
| `explain` | Explains what the code does and why |
| `explore` | Finds callers, dependencies and related code, with `path:line` references |
| `deep` | Looks for bugs, edge cases and missing tests, and lists them as findings |
| `ask` | Answers your question |
| `review` | Reviews the whole change and marks each finding at its line (review tab only) |

## Keys

| Where | Key | What it does |
| --- | --- | --- |
| Files panel | `<CR>` | Open the file |
| | `f` | Go to a file |
| | `v` | Toggle viewed |
| | `t` | Run the tour again |
| | `r` | Review the whole change |
| Files panel, agent pane | `C` | Add every finding to your pending GitHub review |
| | `S` | Submit your GitHub review |
| Agent pane | `<CR>`, `gf` | Jump to the `path:line` under the cursor |
| | `c` | Draft a GitHub comment from the finding |
| Diff | `]c`, `[c` | Next or previous hunk |
| Go-to-file picker | `j`, `k` | Move between files |
| | `/` | Filter by a fuzzy match on the path |
| | `v` | Toggle viewed |
| Answer float | `a` | Ask a follow-up |
| | `<CR>`, `gf` | Jump to the `path:line` under the cursor |
| | `s` | Move the answer to a right split |
| | `<C-c>` | Cancel the answer |
| Thread float | `r` | Reply to the thread under the cursor |
| Comment and summary float | `:w`, `<C-s>` | Send |
| | `gs` | Insert a `suggestion` block with the selected lines |
| Every float, files panel | `q` | Close |

## Configuration

```lua
{
  agent = "claude", -- adapter name, or an adapter table
  adapters = {},
  model = nil, -- every action not in `models`
  models = {}, -- model per action, e.g. { deep = "opus" }
  files_height = 8, -- files panel at the bottom, in rows
  agent_width = 0.33, -- agent pane and the quick split, as a fraction of the screen
  agent_height = 0.33, -- agent pane under the diff, as a fraction of the screen
  min_diff_width = 80, -- narrowest diff pane before the agent pane moves under the diff
  images = true, -- show changed images side by side instead of a binary file note
  float_width = 100,
  float_height = 15,
  auto_tour = true, -- overview and reading order when a review opens
  max_context_lines = 300, -- longest hunk or selection sent with an action
  max_tour_lines = 1500, -- diff sent with the tour to agents without a shell
  review_prompt = nil, -- your own review prompt or slash command, see :h agentic-review-review-prompt
}
```

### Custom adapters

An adapter is a table in `adapters`, picked by name with `agent`. The built-in ones in `lua/agentic_review/init.lua` are complete examples.

| Field | Meaning |
| --- | --- |
| `cmd(ctx)` | Returns the argv, and optionally a session id. `ctx` has `system`, `prompt`, `session`, `root`, `label` and `model` |
| `persistent` | Start the process once and write each prompt to its stdin with `encode(prompt)` |
| `models` | Default model per action (`tour`, `explain`, `explore`, `deep`, `ask`, `review`) |
| `set_model(model)` | Returns a stdin line that switches a running persistent process to `model` |
| `parse(line, emit)` | Turns one stdout line into `emit.text(s)`, `emit.tool(name, input)`, `emit.session(id)` and `emit.done(err)` |
| `shell` | Whether the agent can run git |

### Highlights

Each group is defined with `default`, so your own `vim.api.nvim_set_hl()` wins.

| Group | Used for | Default |
| --- | --- | --- |
| `AgenticReviewHigh`, `AgenticReviewMedium`, `AgenticReviewLow`, `AgenticReviewQuestion` | Finding severity tags | Badges in the `DiagnosticError`, `DiagnosticWarn`, `DiagnosticInfo` and `DiagnosticHint` colours |
| `AgenticReviewTitle` | Finding titles | `Title` |
| `AgenticReviewTool` | Tool names in tool call lines | `Function` |
| `AgenticReviewCommand` | Commands and paths in tool call lines | `String` |
| `AgenticReviewRef` | `path:line` references | `Underlined` |
| `AgenticReviewMeta` | Answer times and cancellations | `Comment` |
| `AgenticReviewError` | Agent errors | `DiagnosticError` |

## Development

```sh
tests/run.sh                  # every spec, each in its own headless Neovim, with a fake agent and a fake gh
tests/run.sh github_spec.lua  # one spec
stylua --check lua tests
```

## License

MIT
