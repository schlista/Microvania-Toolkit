-- hooks/core/context.lua
--
-- Explicit shared context for the split editor hook chunks.
--
-- The editor hook is too large to live in a single file, so the chunks are
-- split across `hooks/editor_core.lua`, `hooks/editor_generators.lua`,
-- `hooks/editor_commands.lua` and `hooks/editor_script.lua`. Each chunk
-- pulls the shared MVTK table from this module via `Context.require_context()`
-- instead of relying on globals.
--
-- ## Required context shape
-- `editor_core.lua` is the only place that calls `Context.set(...)`. The
-- table it stores groups roughly into the following categories — split
-- chunks should only read what they need and avoid mutating shared state
-- outside `ctx.dirty` (a flag set when the chunk wrote files and the editor
-- needs to refresh):
--
--   editor_api      `editor` userdata exposed by Defold (only when not HEADLESS).
--   HEADLESS        true when running under the Lua-only test runner / CLI.
--   ROOT, DIR_SEP   project root + path separator for filesystem ops.
--   PATH            normalised path helpers (join, to_os_path, ...).
--   TILED_CONFIG    parsed Tiled paths config used by the export pipeline.
--   TILED_MAPS_RESOURCE_DIR / GENERATED_ROOMS_RESOURCE_DIR
--                   /-prefixed resource paths used by `ensure_*` writers.
--   info / profiler logging + timing helpers (always defined; profiler may noop).
--   lfs_ok / lfs    LuaFileSystem availability + handle when present.
--   load_tiled_export / get_png_dimensions / get_tileset_meta / ...
--                   filesystem + Tiled IO helpers shared by every chunk.
--   gen_collection  set by `editor_generators.lua` after registration so
--                   `editor_script.lua` and tests can call it back.
--   dirty           bool flag any chunk may set to ask the host to refresh.
--
-- This list is descriptive, not exhaustive: see `editor_core.lua`'s call
-- to `_context.set({...})` for the canonical field list.

local M = {}

local current

function M.set(ctx)
    assert(type(ctx) == "table", "hooks.core.context.set expects a table")
    current = ctx
    return ctx
end

function M.get()
    return current
end

function M.require_context(caller)
    local ctx = M.get()
    if not ctx then
        error("MVTK editor context is not initialized" .. (caller and (": " .. tostring(caller)) or ""), 2)
    end
    return ctx
end

function M.update(values)
    local ctx = M.require_context("update")
    for key, value in pairs(values or {}) do
        ctx[key] = value
    end
    return ctx
end

return M
