--- Obsidian cache: ORM-style repository over swappable backend.
---
--- v2 stores typed note and attachment rows behind separate repositories.
--- Wired to LSP document-save and watched-file events for live updates.

local log = require "obsidian.log"
local watchfiles = require "obsidian.lsp.watchfiles"
local cache_note = require "obsidian.cache.note"
local filetypes = require "obsidian.filetypes"
local ignore = require "obsidian.ignore"

local M = {}
M.find_files = require("obsidian.cache.api").find_files

---@class obsidian.cache.Backend
---@field open fun(opts: table): obsidian.cache.Store

---@class obsidian.cache.Store
---@field close fun(self: obsidian.cache.Store)?
---@field flush fun(self: obsidian.cache.Store)?
---@field get fun(self: obsidian.cache.Store, key: string): table?
---@field all fun(self: obsidian.cache.Store): table<string, table>
---@field put fun(self: obsidian.cache.Store, key: string, row: table)
---@field delete fun(self: obsidian.cache.Store, key: string)

---@class obsidian.cache.FileStat
---@field size integer
---@field mtime_sec integer
---@field mtime_nsec integer

---@class obsidian.cache.NoteRow
---@field kind "note"
---@field stat obsidian.cache.FileStat
---@field aliases? string[]
---@field tags? string[]
---@field properties? table<string, any>
---@field links_out? table[]
---@field tasks? table[]

---@class obsidian.cache.AttachmentRow
---@field kind "attachment"
---@field stat obsidian.cache.FileStat
---@field extension string

---@alias obsidian.cache.Row obsidian.cache.NoteRow|obsidian.cache.AttachmentRow

---@class obsidian.cache.HeadingRow
---@field path string
---@field header string
---@field anchor string
---@field level integer
---@field line integer 1-based

---@type table<string, any>
local backends = {
  json = require "obsidian.cache.json_backend",
  memory = require "obsidian.cache.memory_backend",
}

---@class obsidian.cache.State
---@field backend obsidian.cache.Store
---@field vault string
---@field flush_timer uv.uv_timer_t|nil
---@field unregister fun()|nil
---@field ready boolean
---@field pending fun()[]
---@field scan_touched table<string, true>|nil paths changed by watched-file events during the running scan

---@type obsidian.cache.State?
local state = nil
local generation = 0

local FLUSH_DEBOUNCE_MS = 2000

---@param abs_path string
---@param kind "note"|"attachment"
---@return obsidian.cache.Row?
local function build_row(abs_path, kind)
  if not state then
    return nil
  end

  if kind == "note" then
    return cache_note.build(abs_path, state.vault)
  end

  local stat = vim.uv.fs_stat(abs_path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  return {
    kind = "attachment",
    stat = {
      mtime_sec = stat.mtime.sec,
      mtime_nsec = stat.mtime.nsec,
      size = stat.size,
    },
    extension = filetypes.extension(abs_path),
  }
end

---@param abs_path string
---@return boolean
local function is_in_vault(abs_path)
  if not state then
    return false
  end
  local root = state.vault:gsub("/+$", "")
  return abs_path == root or vim.startswith(abs_path, root .. "/")
end

---@param abs_path string
---@return boolean
local function is_internal(abs_path)
  if not state then
    return true
  end
  local root = state.vault:gsub("/+$", "")
  local rel = abs_path
  if vim.startswith(abs_path, root .. "/") then
    rel = abs_path:sub(#root + 2)
  end
  local first = rel:match "^([^/\\]+)"
  local opts = Obsidian.opts or {}
  local config_dir = opts.sync and opts.sync.config_dir or ".obsidian"
  return first == config_dir or first == ".git"
end

local function schedule_flush()
  if not state then
    return
  end
  generation = generation + 1
  if not state.backend.flush then
    return
  end
  if state.flush_timer then
    state.flush_timer:stop()
    state.flush_timer:close()
  end
  local timer
  timer = vim.defer_fn(function()
    if not state or state.flush_timer ~= timer then
      return
    end
    state.flush_timer = nil
    if state.backend then
      local ok, err = pcall(function()
        state.backend:flush()
      end)
      if not ok then
        log.err("[cache] flush failed: %s", err)
      end
    end
  end, FLUSH_DEBOUNCE_MS)
  state.flush_timer = timer
end

---@param abs_path string
---@return boolean
local function is_ignored(abs_path)
  if not state then
    return true
  end
  -- TODO: if users need cache-specific ignore behavior, add an option to override
  -- this. For now cache follows the global file.ignore_filters path.
  return ignore.is_ignored(abs_path)
end

---@param abs_path string
local function reindex_one(abs_path)
  if not state then
    return
  end
  abs_path = vim.fs.normalize(abs_path)
  if not is_in_vault(abs_path) then
    return
  end
  local kind = filetypes.kind(abs_path)
  if not kind or is_internal(abs_path) or is_ignored(abs_path) then
    state.backend:delete(abs_path)
    schedule_flush()
    return
  end
  local row = build_row(abs_path, kind)
  if row then
    state.backend:put(abs_path, row)
  else
    -- A missing or malformed file must not leave structured data from an older
    -- version of the file visible through the cache.
    state.backend:delete(abs_path)
  end
  schedule_flush()
end

---@param abs_path string
local function remove_one(abs_path)
  if not state then
    return
  end
  state.backend:delete(vim.fs.normalize(abs_path))
  schedule_flush()
end

---@param old_path string
---@param new_path string
local function rename_one(old_path, new_path)
  if not state then
    return
  end
  old_path = vim.fs.normalize(old_path)
  new_path = vim.fs.normalize(new_path)
  local kind = filetypes.kind(new_path)
  if not is_in_vault(new_path) or not kind or is_internal(new_path) or is_ignored(new_path) then
    state.backend:delete(old_path)
    schedule_flush()
    return
  end
  local row = build_row(new_path, kind)
  if not row then
    state.backend:delete(old_path)
    schedule_flush()
    return
  end
  state.backend:delete(old_path)
  state.backend:put(new_path, row)
  schedule_flush()
end

---@param ev table
---@return string?
local function event_path(ev)
  if ev.path then
    return vim.fs.normalize(ev.path)
  elseif ev.uri then
    return vim.fs.normalize(vim.uri_to_fname(ev.uri))
  end
end

---@param events table[]
local function on_events(events)
  local FileChangeType = vim.lsp.protocol.FileChangeType
  for _, ev in ipairs(events) do
    local path = event_path(ev)
    local touched = state and state.scan_touched
    if touched then
      for _, p in pairs { path, ev.old_path, ev.new_path } do
        touched[vim.fs.normalize(p)] = true
      end
    end
    if
      ev.type == "created"
      or ev.type == "changed"
      or ev.type == FileChangeType.Created
      or ev.type == FileChangeType.Changed
    then
      if path then
        reindex_one(path)
      end
    elseif ev.type == "deleted" or ev.type == FileChangeType.Deleted then
      if path then
        remove_one(path)
      end
    elseif ev.type == "renamed" then
      rename_one(ev.old_path, ev.new_path)
    end
  end
end

---@param row obsidian.cache.Row
---@param stat uv.fs_stat.result
---@return boolean
local function stat_matches(row, stat)
  local cached = row.stat
  return cached ~= nil
    and cached.mtime_sec == stat.mtime.sec
    and cached.mtime_nsec == stat.mtime.nsec
    and cached.size == stat.size
end

---@param row obsidian.cache.Row?
---@param path string
---@param stat uv.fs_stat.result
---@return boolean
local function entry_matches(row, path, stat)
  local kind = filetypes.kind(path)
  if type(row) ~= "table" or not kind or row.kind ~= kind or not stat_matches(row, stat) then
    return false
  end
  return kind ~= "attachment" or row.extension == filetypes.extension(path)
end

---Run a libuv fs request on the thread pool and its callback on the main loop
---(`async`), or run both inline.
---@param async boolean
---@param fn fun(path: string, cb: function?): any
---@param path string
---@param cb fun(err: string?, result: any)
local function fs_request(async, fn, path, cb)
  if async then
    fn(path, vim.schedule_wrap(cb))
  else
    local result, err = fn(path)
    cb(err, result)
  end
end

---Walk vault, populate cache for all supported notes and attachments. Skips entries whose mtime/size match.
---
---With `opts.async`, directory reads and stats run on libuv's thread pool and
---each result is handled in its own main-loop callback, so a large vault never
---blocks the editor for the whole walk; `opts.on_done` runs once the cache
---matches the vault. Without it, the walk finishes before this returns.
---@param opts { force: boolean?, async: boolean?, on_done: fun()? }?
local function initial_scan(opts)
  opts = opts or {}
  if not state then
    return
  end
  local scan_state = state
  local async = opts.async == true
  local found = {}
  -- Paths changed by watched-file events while an async walk is in flight: the
  -- walk may have read their directory before they appeared, so their absence
  -- from `found` does not mean they are gone.
  local touched = {}
  scan_state.scan_touched = touched
  local pending = 0
  local finished = false

  local function cancelled()
    return state ~= scan_state or scan_state.scan_touched ~= touched
  end

  local function finish_if_idle()
    if pending > 0 or finished or cancelled() then
      return
    end
    finished = true
    scan_state.scan_touched = nil
    for path, _ in pairs(scan_state.backend:all()) do
      local normalized = vim.fs.normalize(path)
      if not found[normalized] and not touched[normalized] then
        scan_state.backend:delete(path)
        schedule_flush()
      end
    end
    if opts.on_done then
      opts.on_done()
    end
  end

  local function check_file(path)
    pending = pending + 1
    fs_request(async, vim.uv.fs_stat, path, function(_, stat)
      pending = pending - 1
      if not cancelled() and stat and (opts.force or not entry_matches(scan_state.backend:get(path), path, stat)) then
        reindex_one(path)
      end
      finish_if_idle()
    end)
  end

  local function visit_dir(dir)
    pending = pending + 1
    fs_request(async, vim.uv.fs_scandir, dir, function(_, req)
      if req and not cancelled() then
        while true do
          local name, type_ = vim.uv.fs_scandir_next(req)
          if not name then
            break
          end
          local path = dir .. "/" .. name
          if type_ == "directory" then
            -- Everything below an internal directory is internal too.
            if not is_internal(path) then
              visit_dir(path)
            end
          elseif type_ == "file" and filetypes.kind(name) and not is_internal(path) and not is_ignored(path) then
            path = vim.fs.normalize(path)
            found[path] = true
            check_file(path)
          end
        end
      end
      -- Decremented only after the entries are queued, so a synchronous walk
      -- cannot reach zero (and finish) while this directory is half done.
      pending = pending - 1
      finish_if_idle()
    end)
  end

  visit_dir(scan_state.vault)
end

local function mark_ready()
  if not state then
    return
  end
  state.ready = true
  local pending = state.pending
  state.pending = {}
  for _, fn in ipairs(pending) do
    local ok, err = pcall(fn)
    if not ok then
      log.err("[cache] pending callback failed: %s", err)
    end
  end
end

---Run `fn` now if cache ready, else queue until initial scan finishes.
---@param fn fun()
function M.when_ready(fn)
  if not state then
    return fn()
  end
  if state.ready then
    return fn()
  end
  state.pending[#state.pending + 1] = fn
end

---@return boolean
function M.is_ready()
  return state ~= nil and state.ready
end

---@return boolean
function M.is_enabled()
  return state ~= nil
end

---Return a version that changes whenever cached rows are mutated.
---@return integer
function M.generation()
  return generation
end

---Register a cache backend.
---@param name string
---@param backend obsidian.cache.Backend
function M.register_backend(name, backend)
  backends[name] = backend
end

---Alias for register_backend(), matching other backend registries.
---@param name string
---@param backend obsidian.cache.Backend
function M.register(name, backend)
  M.register_backend(name, backend)
end

---@param name string?
---@return obsidian.cache.Backend?
function M.get_backend(name)
  local backend = backends[name or "json"]
  ---@cast backend obsidian.cache.Backend?
  return backend
end

---@param opts obsidian.config.CacheOpts
function M.setup(opts)
  opts = opts or {}
  if opts.enabled == false then
    M.shutdown()
    return
  end

  M.shutdown()

  local vault = vim.fs.normalize(tostring(Obsidian.dir))
  local stdpath_cache = vim.fn.stdpath "cache"
  ---@cast stdpath_cache string
  local cache_root = vim.fs.joinpath(stdpath_cache, "obsidian.nvim", vim.fn.sha256(vault):sub(1, 16))
  local cache_path = vim.fs.joinpath(cache_root, "index.json")

  local backend_name = opts.backend or "json"
  if backend_name == "json" then
    vim.fn.mkdir(cache_root, "p")
  end
  local backend_impl = M.get_backend(backend_name)
  if not backend_impl then
    error("cache: unknown backend '" .. tostring(backend_name) .. "'")
  end
  local backend = backend_impl.open(
    vim.tbl_extend("force", vim.deepcopy(opts), { path = cache_path, root = cache_root, vault = vault })
  )

  state = {
    backend = backend,
    vault = vault,
    flush_timer = nil,
    unregister = nil,
    ready = false,
    pending = {},
  }

  state.unregister = watchfiles.register_handler(function(events)
    on_events(events)
  end)

  local setup_state = state
  vim.schedule(function()
    if state ~= setup_state then
      return
    end
    initial_scan { async = true, on_done = mark_ready }
  end)

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("obsidian-cache-flush", { clear = true }),
    callback = function()
      M.shutdown()
    end,
  })
end

function M.shutdown()
  if not state then
    return
  end
  if state.flush_timer then
    state.flush_timer:stop()
    state.flush_timer:close()
    state.flush_timer = nil
  end
  if state.unregister then
    state.unregister()
    state.unregister = nil
  end
  if state.backend then
    pcall(function()
      if state.backend.close then
        state.backend:close()
      end
    end)
  end
  state = nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Notes repository (CRUD)
-- ──────────────────────────────────────────────────────────────────────────────

---@class obsidian.cache.NotesRepo
M.notes = {}

---@param row obsidian.cache.Row?
---@return boolean
local function is_note_row(row)
  return row ~= nil and row.kind == "note"
end

---@param row obsidian.cache.Row?
---@return boolean
local function is_attachment_row(row)
  return row ~= nil and row.kind == "attachment"
end

---@param predicate fun(row: obsidian.cache.Row?): boolean
---@return integer
local function count_rows(predicate)
  if not state or not state.ready then
    return 0
  end
  local count = 0
  for _, row in pairs(state.backend:all()) do
    if predicate(row) then
      count = count + 1
    end
  end
  return count
end

---Count cached outgoing links that target `note`.
---@param note obsidian.Note
---@return integer
function M.notes.backlink_count(note)
  if not state or not state.ready then
    return 0
  end

  local refs = {}
  for _, ref in ipairs(note:get_reference_paths { urlencode = true }) do
    refs[ref:lower()] = true
  end

  local count = 0
  for _, row in pairs(state.backend:all()) do
    for _, link in ipairs(row.links_out or {}) do
      local target = link.target:gsub("^%./", ""):gsub("^/", ""):lower()
      if refs[target] then
        count = count + 1
      end
    end
  end
  return count
end

---Find cached headings whose original text or normalized anchor contains `query`.
---@param query string?
---@return obsidian.cache.HeadingRow[]
function M.notes.find_headings(query)
  if not state or not state.ready then
    return {}
  end

  local needle = vim.fn.tolower(vim.trim(query or ""))
  local results = {}
  for path, row in pairs(state.backend:all()) do
    for _, heading in ipairs(row.headings or {}) do
      local searchable = heading.header .. " " .. heading.anchor
      if needle == "" or vim.fn.tolower(searchable):find(needle, 1, true) then
        results[#results + 1] = vim.tbl_extend("force", heading, { path = path })
      end
    end
  end

  table.sort(results, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.line < b.line
  end)
  return results
end

---@param path string
---@return string
local function rel_path(path)
  assert(state, "cache not initialized")
  local root = state.vault:gsub("/+$", "")
  if vim.startswith(path, root .. "/") then
    return path:sub(#root + 2)
  end
  return path
end

---@param path string  absolute path
---@return obsidian.cache.NoteRow
function M.notes.get(path)
  assert(state and state.ready, "cache not ready")
  local row = state.backend:get(vim.fs.normalize(path))
  if not is_note_row(row) then
    error("cache: no note at " .. path)
  end
  ---@cast row obsidian.cache.NoteRow
  return row
end

---@param path string
---@return obsidian.cache.NoteRow?
function M.notes.find(path)
  if not state or not state.ready then
    return nil
  end
  local row = state.backend:get(vim.fs.normalize(path))
  if is_note_row(row) then
    ---@cast row obsidian.cache.NoteRow
    return row
  end
end

---@return table<string, obsidian.cache.NoteRow>
function M.notes.all()
  assert(state and state.ready, "cache not ready")
  local rows = {}
  for path, row in pairs(state.backend:all()) do
    if is_note_row(row) then
      ---@cast row obsidian.cache.NoteRow
      rows[path] = row
    end
  end
  return rows
end

---@return integer
function M.notes.count()
  return count_rows(is_note_row)
end

---@param path string
---@return string
function M.notes.rel_path(path)
  return rel_path(path)
end

---@param path string
---@return string
function M.notes.basename(path)
  return vim.fn.fnamemodify(path, ":t:r")
end

---@param row table  must include `path`
function M.notes.upsert(row)
  assert(state, "cache not initialized")
  assert(row.path, "row.path required")
  local path = vim.fs.normalize(row.path)
  row = vim.deepcopy(row)
  row.path = nil
  row.kind = "note"
  state.backend:put(path, row)
  schedule_flush()
end

---@param path string
---@param patch table
function M.notes.update(path, patch)
  assert(state, "cache not initialized")
  path = vim.fs.normalize(path)
  local row = state.backend:get(path)
  if not is_note_row(row) then
    error("cache: no note at " .. path)
  end
  ---@cast row obsidian.cache.NoteRow
  for k, v in pairs(patch) do
    row[k] = v
  end
  row.kind = "note"
  state.backend:put(path, row)
  schedule_flush()
end

---@param path string
function M.notes.delete(path)
  if not state then
    return
  end
  path = vim.fs.normalize(path)
  if is_note_row(state.backend:get(path)) then
    state.backend:delete(path)
    schedule_flush()
  end
end

---Refresh one note directly from disk.
---@param path string
function M.notes.refresh(path)
  reindex_one(path)
end

---Replace a cached note path after a successful filesystem rename.
---@param old_path string
---@param new_path string
function M.notes.rename(old_path, new_path)
  rename_one(old_path, new_path)
end

---Force flush to disk (otherwise debounced).
function M.notes.flush()
  if state and state.backend and state.backend.flush then
    state.backend:flush()
  end
end

---Force full rebuild from vault.
function M.notes.reindex()
  if not state then
    return
  end
  initial_scan { force = true }
  -- A synchronous rebuild supersedes a startup scan still in flight, which
  -- then never calls its `on_done`.
  mark_ready()
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Attachments repository (read-only)
-- ──────────────────────────────────────────────────────────────────────────────

---@class obsidian.cache.AttachmentsRepo
M.attachments = {}

---@param path string
---@return obsidian.cache.AttachmentRow
function M.attachments.get(path)
  assert(state and state.ready, "cache not ready")
  local row = state.backend:get(vim.fs.normalize(path))
  if not is_attachment_row(row) then
    error("cache: no attachment at " .. path)
  end
  ---@cast row obsidian.cache.AttachmentRow
  return row
end

---@param path string
---@return obsidian.cache.AttachmentRow?
function M.attachments.find(path)
  if not state or not state.ready then
    return nil
  end
  local row = state.backend:get(vim.fs.normalize(path))
  if is_attachment_row(row) then
    ---@cast row obsidian.cache.AttachmentRow
    return row
  end
end

---@return table<string, obsidian.cache.AttachmentRow>
function M.attachments.all()
  assert(state and state.ready, "cache not ready")
  local rows = {}
  for path, row in pairs(state.backend:all()) do
    if is_attachment_row(row) then
      ---@cast row obsidian.cache.AttachmentRow
      rows[path] = row
    end
  end
  return rows
end

---@return integer
function M.attachments.count()
  return count_rows(is_attachment_row)
end

---@param path string
---@return string
function M.attachments.rel_path(path)
  return rel_path(path)
end

---@param path string
---@return string
function M.attachments.basename(path)
  return vim.fs.basename(path)
end

return M
