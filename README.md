# agentic-review.nvim

Code review in Neovim with a headless coding agent next to the diff.

Open a branch or a GitHub pull request in a review tab: the changed files in a suggested reading order, a side-by-side diff, and a pane where the agent explains, explores or digs into the hunk under the cursor, or reviews the whole change and marks its findings in the diff. Outside a review, the same actions answer in a float under the code you select. Comments you write go to your pending GitHub review, which nobody sees until you submit it.

The agent runs read-only. The plugin drives [Claude Code](https://github.com/anthropics/claude-code) or [pi](https://github.com/earendil-works/pi) out of the box, and any other headless CLI through a small adapter in your config.

## Requirements

- Neovim 0.10 or newer
- git
- An agent CLI: `claude` (Claude Code) or `pi`, logged in, or your own adapter
- The [GitHub CLI](https://cli.github.com) `gh`, logged in, for pull requests and comments
- Optional: a Markdown renderer such as [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) for the agent's answers

Run `:checkhealth agentic_review` to see what is missing.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "AlucarDWeb/agentic-review.nvim",
  cmd = { "Review", "ReviewClose", "ReviewCancel", "ReviewRefs", "ReviewAsk", "ReviewComment", "ReviewSubmit", "ReviewFiles" },
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

The plugin sets no global keymaps; the table above is a suggestion. Without lazy.nvim, call `require("agentic_review").setup({})` once.

## Reviewing a branch or a pull request

| Command | What it reviews |
| --- | --- |
| `:Review` | The current branch against its merge-base with `origin/HEAD` (falling back to `origin/main`, `origin/master`, `main`, `master`), uncommitted changes included |
| `:Review <ref>` | The same, against another base: `:Review origin/develop`, or `:Review HEAD` for uncommitted changes only |
| `:Review #123` | A pull request, through `gh`. It is fetched, not checked out, so the head side shows read-only revisions. If the PR is already checked out, the head side is your working tree and LSP works there |
| `:Review!` | Any of the above, ignoring the saved session |

The review opens in its own tab: the base and head versions in Neovim's diff mode with the agent pane on their right, and the changed files in a panel across the bottom. When three columns would leave a diff pane narrower than `min_diff_width`, the diff takes the full width and the agent pane moves under it, above the files. For an added or deleted file, the diff side with content takes the empty side's width. On open the agent writes a short overview and reorders the files into a suggested reading order (`auto_tour`).

- Files panel: `<CR>` opens a file, `f` goes to a file, `v` toggles viewed, `t` runs the tour again, `r` reviews the whole change, `q` closes the review
- Diff: `]c` and `[c` move between hunks
- Agent pane: `<CR>` or `gf` jumps to the `path:line` under the cursor, `c` on a review finding drafts a GitHub comment from it

### Going to a file

`:ReviewFiles`, `require("agentic_review").files()` or `f` in the files panel opens a float with the changed files as a tree grouped by directory. Each row shows the status, `●` for the open file and `✓` for viewed ones, a badge with the number of review findings and their worst severity, and the lines added and removed.

| Key | Effect |
| --- | --- |
| `j`, `k` | Move between files |
| `/` | Filter the files by a fuzzy match on their path, as you type. `<CR>` opens the selected match, `<Esc>` goes back to the list |
| `<CR>` | Open the file |
| `v` | Toggle viewed |
| `q`, `<Esc>` | Close |

### Images

A changed PNG, JPEG, GIF, BMP, WebP, TIFF, HEIC or AVIF file shows the old version on the base side and the new one on the head side instead of a diff. The images need [snacks.nvim](https://github.com/folke/snacks.nvim) with `image.enabled` and a terminal that speaks the kitty graphics protocol, such as kitty, Ghostty or WezTerm, or tmux running inside one of them. Without them, each side shows the format, dimensions and size, and `gx` opens that version in your image viewer.

A multiplexer that forwards kitty graphics but answers the terminal query as itself, such as herdr inside Ghostty, needs `SNACKS_GHOSTTY=1` (or `SNACKS_KITTY=1`) in the environment so snacks.nvim uses the graphics protocol. `images = false` turns previews off.

The agent's session, the file order, viewed marks and the pane transcript are saved under `stdpath("state")`. Running the same `:Review` again resumes the session and skips the tour. Untracked files do not appear, because `git diff` ignores them; `git add -N <file>` makes them show up.

## Asking the agent

| Function | Prompt |
| --- | --- |
| `action("explain")` | What the code does and why it is written that way |
| `action("explore")` | Callers, dependencies and related code, with `path:line` references |
| `action("deep")` | Correctness bugs, edge cases, lifecycle and concurrency problems, missing tests, each checked against the code |
| `action("ask")` | Your own question (`:ReviewAsk [question]` takes a range) |
| `action("review")` | The whole change, in passes: behaviour against the base, lifecycle, threading, data flow, test coverage, CLAUDE.md files, code comments and git history. Only correctness and behaviour findings the agent is at least 80% sure of, ranked high, medium, low or question, each at a `path:line`. Review tab only |

A review lists its findings in the agent pane, where `<CR>` jumps to each one and `c` drafts a GitHub comment from it, and shows each finding at the end of its line in the diff. The findings are saved with the review.

In normal mode an action uses the hunk under the cursor, in visual mode the selection, and in the files panel the whole file. In the review tab the answer streams into the agent pane, which keeps the review conversation.

Outside the review tab, in any buffer, the answer opens in a float under the selected code (or the cursor line plus 5 lines each side). It opens above the code near the bottom of the window and grows with the answer up to `float_height`. Each question asked from the code starts a new thread with a fresh agent session, and `a` asks a follow-up in that thread.

| Key in the float | Effect |
| --- | --- |
| `a` | Ask a follow-up |
| `<CR>`, `gf` | Jump to the `path:line` under the cursor |
| `s` | Move the answer to a right split; the next question replaces it there until you close the split |
| `<C-c>` | Cancel the running answer |
| `q`, `<Esc>` | Close |

`require("agentic_review").answer()` reopens the last answer, and `:ReviewRefs` sends every `path:line` in it to the quickfix list.

## Commenting on GitHub

On a line or selection in the diff, `:ReviewComment` (or `require("agentic_review").comment()`) opens a float for the comment. `:w`, `:wq` or `<C-s>` adds it to your pending review on the pull request, `gs` inserts a `suggestion` block with the selected lines, and `q` cancels. On a line with a review finding, the float starts with the finding's text, ready to edit. `:ReviewSubmit` submits the review as Comment, Approve or Request changes.

Only a write command typed in the float sends the comment, so autosave setups that run `:wall` on `InsertLeave` or `TextChanged` do not post drafts. Before anything is sent, the plugin refuses:

- lines outside a hunk, which GitHub does not accept
- a local `HEAD` that differs from the PR head
- head side comments on a file with unpushed or unsaved changes

In each of these cases the line numbers would not match GitHub. For a branch review, the PR is the one `gh pr view` finds for the branch.

## Agents

`claude` runs `claude -p` with stream-json input and output as one process per conversation. Its tools are limited to `Read`, `Grep`, `Glob` and single `git diff`, `show`, `log`, `blame` and `grep` commands, with `--permission-mode dontAsk` and `--strict-mcp-config`. Your Claude Code hooks and `CLAUDE.md` files still apply.

`pi` runs `pi --mode rpc` with `read`, `grep`, `find` and `ls`, and without extensions, skills or MCP. pi cannot limit `bash` to git commands, so it gets no shell, and each message includes the diff it needs.

Each action can run on its own model, passed to the agent's `--model` flag. See [Configuration](#configuration).

### Custom adapters

An adapter is a table in `adapters`, picked by name with `agent`:

| Field | Meaning |
| --- | --- |
| `cmd(ctx)` | Returns the argv, and optionally a session id. `ctx` has `system`, `prompt`, `session`, `root`, `label` and `model` |
| `persistent` | When true, the process starts once and each prompt is written to its stdin with `encode(prompt)` |
| `models` | Default model per action (`tour`, `explain`, `explore`, `deep`, `ask`, `review`), used when `models` and `model` in your config leave it out |
| `set_model(model)` | Returns a stdin line that switches a running persistent process to `model`. Without it, a model change restarts the process on the same session |
| `parse(line, emit)` | Turns one stdout line into `emit.text(s)`, `emit.tool(name, input)`, `emit.session(id)` and `emit.done(err)` |
| `shell` | Whether the agent can run git; the system prompt changes accordingly |

Without `parse`, stdout streams into the answer as plain text and the end of the process ends the answer. A minimal one-shot adapter:

```lua
opts = {
  agent = "mycli",
  adapters = {
    mycli = {
      cmd = function(ctx)
        return { "mycli", "--print", ctx.system .. "\n\n" .. ctx.prompt }
      end,
    },
  },
}
```

That adapter starts from scratch on every question. A `persistent` one with `parse`, or a `cmd` that resumes `ctx.session`, keeps the conversation. The built-in adapters in `lua/agentic_review/init.lua` are complete examples.

## Configuration

Defaults:

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
}
```

Each action picks its model from `models`, then `model`, then the adapter's own defaults. The claude adapter runs `deep` and `review` on opus and the other actions on sonnet. The agent pane and the float show the model that is answering.

### Highlights

The agent pane and the float colour their lines with these groups, each defined with `default`, so a `vim.api.nvim_set_hl()` in your config wins:

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
tests/run.sh                  # every spec, each in its own headless Neovim
tests/run.sh github_spec.lua  # one spec
stylua --check lua tests
```

The specs build a throwaway git repository and use fake agents and a fake `gh`, so they need neither network access nor accounts.

## License

MIT
