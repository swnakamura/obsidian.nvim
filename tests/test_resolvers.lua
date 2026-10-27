local Note = require "obsidian.note"
local docs = require "obsidian.completion.docs"
local resolvers = require "obsidian.resolvers"

local new_set, eq = MiniTest.new_set, MiniTest.expect.equality

local T = new_set()

--- Build an in-memory note whose contents were not parsed (like cache-built
--- notes with lazily loaded contents).
---@param lines string[]
---@return obsidian.Note
local function raw_note(lines)
  local note = Note.new("foo", {}, {}, "/tmp/vault/foo.md")
  note.contents = lines
  return note
end

T["default_note_preview"] = new_set()

T["default_note_preview"]["resolves the title from frontmatter metadata"] = function()
  local note = raw_note { "---", "tags: []", "---", "# H1 Heading" }
  note.metadata = { title = "Metadata Title" }
  local out = resolvers.default_note_preview { scope = "lsp.completion", note = note }
  eq(true, out:find("**title:** Metadata Title", 1, true) ~= nil)
end

T["default_note_preview"]["resolves the title from the first H1 section"] = function()
  local note = Note.new("foo", {}, {}, "/tmp/vault/foo.md")
  note.sections = {
    { header = nil, level = nil, anchor = nil },
    { header = "Intro", level = 1, anchor = "#intro" },
    { header = "Nested", level = 2, anchor = "#intro#nested" },
  }
  -- No contents at all: the title comes from the sections alone.
  local out = resolvers.default_note_preview { scope = "lsp.completion", note = note }
  eq(true, out:find("**title:** Intro", 1, true) ~= nil)
end

T["default_note_preview"]["skips sub-headings when looking for the H1 section"] = function()
  local note = Note.new("foo", {}, {}, "/tmp/vault/foo.md")
  note.sections = {
    { header = "Only H2", level = 2, anchor = "#only-h2" },
  }
  note.contents = { "# Real Title" }
  local out = resolvers.default_note_preview { scope = "lsp.completion", note = note }
  eq(nil, out:find("Only H2", 1, true))
  eq(true, out:find("**title:** Real Title", 1, true) ~= nil)
end

T["default_note_preview"]["skips frontmatter when contents were not parsed"] = function()
  local note = raw_note { "---", "# a yaml comment", "title: x", "---", "", "# Real Title" }
  note.metadata = { title = "x" }
  -- The metadata title wins outright.
  local out = resolvers.default_note_preview { scope = "lsp.completion", note = note }
  eq(true, out:find("**title:** x", 1, true) ~= nil)

  -- Without metadata, the yaml comment must not be picked up as the H1.
  note.metadata = {}
  out = resolvers.default_note_preview { scope = "lsp.completion", note = note }
  eq(true, out:find("**title:** Real Title", 1, true) ~= nil)
end

T["default_note_preview"]["ignores H1s inside code fences and comments"] = function()
  local note = raw_note {
    "```markdown",
    "# Fenced Heading",
    "```",
    "%%",
    "# Commented Heading",
    "%%",
    "# Real Heading",
  }
  local out = resolvers.default_note_preview { scope = "lsp.completion", note = note }
  eq(true, out:find("**title:** Real Heading", 1, true) ~= nil)
  eq(nil, out:find("Fenced Heading", 1, true))
  eq(nil, out:find("Commented Heading", 1, true))
end

T["resolve_item"] = new_set()

T["resolve_item"]["passes items without data through unchanged"] = function()
  local item = { label = "[[foo]]" }
  local result
  docs.resolve_item(item, function(resolved)
    result = resolved
  end)
  eq(item, result)
  eq(nil, result.documentation)
end

T["resolve_item"]["passes items with an unknown key through unchanged"] = function()
  local item = { label = "[[foo]]", data = { obsidian_note_preview = 424242 } }
  local result
  docs.resolve_item(item, function(resolved)
    result = resolved
  end)
  eq(item, result)
  eq(nil, result.documentation)
end

T["resolve_item"]["passes items with non-table data through unchanged"] = function()
  local item = { label = "[[foo]]", data = 42 }
  local result
  docs.resolve_item(item, function(resolved)
    result = resolved
  end)
  eq(item, result)
  eq(nil, result.documentation)
end

T["register"] = new_set {
  hooks = {
    pre_case = function()
      _G.saved_obsidian = rawget(_G, "Obsidian")
      -- Echo the label so each test can tell which registrations are still resolvable.
      _G.Obsidian = {
        opts = {
          resolvers = {
            note_preview = function(ctx, done)
              done(ctx.label)
            end,
          },
        },
      }
    end,
    post_case = function()
      _G.Obsidian = _G.saved_obsidian
      _G.saved_obsidian = nil
    end,
  },
}

local function resolved_label(data)
  local label
  docs.resolve_item({ data = data }, function(item)
    label = item.documentation and item.documentation.value
  end)
  return label
end

T["register"]["evicts previous requests before a large current response"] = function()
  local note = Note.new("foo", {}, {}, "/tmp/vault/foo.md")
  docs.begin_request()
  local previous = {}
  for i = 1, 3000 do
    previous[i] = docs.register { note = note, label = "previous " .. i }
  end
  eq("previous 1", resolved_label(previous[1]))

  docs.begin_request()
  local current = {}
  for i = 1, 3000 do
    current[i] = docs.register { note = note, label = "current " .. i }
  end
  eq(nil, resolved_label(previous[3000]))
  eq("current 1", resolved_label(current[1]))
  eq("current 3000", resolved_label(current[3000]))
end

T["register"]["caps a request that never ends"] = function()
  local note = Note.new("foo", {}, {}, "/tmp/vault/foo.md")
  docs.begin_request()
  local data = {}
  for i = 1, 5000 do
    data[i] = docs.register { note = note, label = "entry " .. i }
  end
  eq(nil, resolved_label(data[904]))
  eq("entry 905", resolved_label(data[905]))
  eq("entry 5000", resolved_label(data[5000]))
end

return T
