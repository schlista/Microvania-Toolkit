-- tools/validate_tiled_export.lua
-- Schema-aware validator for Tiled Lua exports under developer/assets/tiled/maps.
--
-- Goals:
--   * Confirm each export is a loadable Lua chunk that returns a table.
--   * Verify the required Tiled top-level fields are present.
--   * Verify every objectgroup object has a `type` field that is a known
--     spawner registry whitelist entry. Untyped helper objects (regions,
--     waypoints, etc.) are tolerated but reported as INFO so authors can
--     audit them.
--   * Optionally check for an MVTK template-version marker on the map and on
--     each object that supplies one, and warn when they fall outside the
--     supported range advertised in tiled/template_versions.lua.
--   * Verify visual/terrain tile layers only use the same primary tileset range
--     the Defold tilemap generator can emit. Grapple tags accept any nonzero gid.
--
-- CLI usage:
--   lua tools/validate_tiled_export.lua                 -- validate all maps
--   lua tools/validate_tiled_export.lua --quick         -- shorter output
--   lua tools/validate_tiled_export.lua path/to/map.lua -- validate one file
--
-- Exit codes:
--   0 = all maps validated successfully
--   1 = one or more maps failed schema validation
--   2 = no maps found / IO failure / catastrophic load error
--
-- The hooks/editor_script.lua integration imports this module via the same
-- mechanism as tools/validate_config.lua so a bad export fails the editor
-- "Validate All" command with a clear, actionable message.

local M = {}
local TilesetSelection = require "mvtk.editor.tileset_selection"
local TilemapRegen = require "mvtk.editor.tilemap_regen"
local TileCollision = require "mvtk.tiled.tile_collision"
local VisualOwnership = require "mvtk.tiled.visual_ownership"
local TileOccupancy = require "mvtk.tiled.tile_occupancy"
local PropertyFlattener = require "mvtk.tiled.property_flattener"
local RetiredTypes = require "mvtk.tiled.retired_types"

-- Default search root, overridable via env or function argument.
local DEFAULT_MAPS_DIR = "developer/assets/tiled/maps"

-- Tiled top-level fields we require for any successful export.
local REQUIRED_TOP_LEVEL = {
  "version", "orientation", "width", "height",
  "tilewidth", "tileheight", "layers", "tilesets",
}

-- Layer-level types Tiled emits. We accept all of these; objects only appear
-- inside `objectgroup` entries (possibly nested under `group`).
local KNOWN_LAYER_TYPES = {
  tilelayer = true,
  objectgroup = true,
  imagelayer = true,
  group = true,
}

-- Keep this list in sync with the Tiled exporter and
-- hooks/editor_commands.lua -> MAP_MUSIC_PROPERTY_NAMES.
local MAP_MUSIC_PROPERTY_NAMES = { "music", "Music", "ambience", "Ambience" }

-- ----------------------------------------------------------------------------
-- Internal helpers
-- ----------------------------------------------------------------------------

local function is_windows()
  return package.config and package.config:sub(1, 1) == "\\"
end

local function read_file(path)
  local fh, err = io.open(path, "rb")
  if not fh then return nil, err end
  local content = fh:read("*a")
  fh:close()
  return content
end

local function normalize_path(path)
  local p = tostring(path or ""):gsub("\\", "/"):gsub("/+", "/")
  local prefix = ""
  if p:match("^[A-Za-z]:/") then
    prefix = p:sub(1, 3)
    p = p:sub(4)
  elseif p:sub(1, 1) == "/" then
    prefix = "/"
    p = p:sub(2)
  end
  local parts = {}
  for part in p:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        parts[#parts] = nil
      elseif prefix == "" then
        parts[#parts + 1] = part
      end
    elseif part ~= "." and part ~= "" then
      parts[#parts + 1] = part
    end
  end
  return prefix .. table.concat(parts, "/")
end

local function dirname(path)
  local p = normalize_path(path or "")
  return p:match("^(.*)/[^/]*$") or "."
end

local function basename(path)
  local p = normalize_path(path or "")
  return p:match("([^/]+)$") or p
end

local function is_abs(path)
  return tostring(path or ""):match("^/") ~= nil
      or tostring(path or ""):match("^[A-Za-z]:[/\\]") ~= nil
end

local function join_path(a, b)
  if is_abs(b) then return normalize_path(b) end
  if not a or a == "" then return normalize_path(b) end
  return normalize_path(tostring(a):gsub("[/\\]+$", "") .. "/" .. tostring(b or ""))
end

local function list_bridge_files(dir, extension_pattern)
  local shared = rawget(_G, "_MVTK")
  if type(shared) ~= "table" or type(shared.list_dir_filesystem) ~= "function" then
    return nil
  end

  local list_dir = dir
  if type(shared.ROOT) == "string" and shared.ROOT ~= "" then
    list_dir = join_path(shared.ROOT, dir)
  end

  local ok_list, _, listed_files = pcall(shared.list_dir_filesystem, list_dir)
  if not ok_list or type(listed_files) ~= "table" then
    return nil
  end

  local files = {}
  for _, file in ipairs(listed_files) do
    if type(file) == "string" and file:match(extension_pattern) then
      files[#files + 1] = file
    end
  end
  if #files == 0 then
    return nil
  end

  table.sort(files)
  return files
end

local function project_root_from_map_path(map_path)
  local p = normalize_path(map_path or "")
  local root = p:match("^(.*)/developer/assets/tiled/maps/[^/]+$")
  if root and root ~= "" then return root end
  if p:match("^developer/assets/tiled/maps/[^/]+$") then return "." end
  return nil
end

local function path_is_within(path, root)
  path = normalize_path(path or "")
  root = normalize_path(root or "")
  if root == "" then
    return not is_abs(path) and path ~= ".." and path:sub(1, 3) ~= "../"
  end
  if is_windows() or root:match("^[A-Za-z]:/") then
    path = path:lower()
    root = root:lower()
  end
  root = root:gsub("/+$", "")
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function resolve_file(ref, base_dir, map_path)
  if not ref or ref == "" then return nil end
  local candidates = {}
  local seen = {}
  local project_root = project_root_from_map_path(map_path)
  local direct_path = is_abs(ref) and normalize_path(ref) or join_path(base_dir, ref)
  local external_ref = project_root ~= nil and not path_is_within(direct_path, project_root)

  local function add_candidate(path, project_local)
    path = normalize_path(path or "")
    if path == "" or seen[path] then return end
    seen[path] = true
    candidates[#candidates + 1] = {
      path = path,
      project_local = project_local == true,
    }
  end

  local function add_project_filename_candidates()
    local filename = basename(ref)
    if not project_root or filename == "" or not filename:lower():match("%.tsx$") then
      return
    end
    -- Keep these basename fallbacks in sync with
    -- hooks/core/tilesource.lua add_project_filename_candidates(). They are
    -- duplicated intentionally so this validator stays standalone in Lua 5.1.
    add_candidate(join_path(project_root, "developer/assets/tiled/tilesets/" .. filename), true)
    add_candidate(join_path(project_root, "developer/assets/tilesheets/" .. filename), true)
    add_candidate(join_path(project_root, "developer/assets/tiled/backgrounds/" .. filename), true)
  end

  -- The editor pipeline prefers an in-project copy when a Tiled reference
  -- escapes the project. Keep resolving that copy so collision diagnostics
  -- inspect the file the build would consume, but validation still rejects
  -- the escaping authored reference below.
  if external_ref then
    add_project_filename_candidates()
  end

  if is_abs(ref) then
    add_candidate(ref, false)
  else
    add_candidate(join_path(base_dir, ref), false)
    add_candidate(ref, false)
  end

  if not external_ref then
    add_project_filename_candidates()
  end

  for _, candidate in ipairs(candidates) do
    local content = read_file(candidate.path)
    if content then
      return candidate.path, content, {
        project_local = candidate.project_local,
        external_ref = external_ref,
      }
    end
  end
  return nil, nil, {
    project_local = false,
    external_ref = external_ref,
  }
end

local function list_tsx_files(dir)
  local files = {}
  dir = normalize_path(dir or ".")
  if dir == "" then dir = "." end

  local bridge_files = list_bridge_files(dir, "%.tsx$")
  if bridge_files then
    for _, file in ipairs(bridge_files) do
      files[#files + 1] = join_path(dir, file)
    end
    return files
  end

  if not io or not io.popen then return files end

  local commands = {}
  if is_windows() then
    local win_dir = dir:gsub("/", "\\"):gsub('"', '""')
    commands[#commands + 1] = string.format('cmd /c dir /b /a-d "%s\\*.tsx" 2>nul', win_dir)
  end
  local unix_dir = dir:gsub("'", "'\\''")
  commands[#commands + 1] = string.format("find '%s' -maxdepth 1 -type f -name '*.tsx' -print 2>/dev/null", unix_dir)
  commands[#commands + 1] = string.format("ls -1 '%s'/*.tsx 2>/dev/null", unix_dir)

  local seen = {}
  for _, cmd in ipairs(commands) do
    local ok_proc, proc = pcall(io.popen, cmd)
    if ok_proc and proc then
      for line in proc:lines() do
        if line and line ~= "" then
          local candidate = line
          if not candidate:find("[/\\]") then
            candidate = join_path(dir, candidate)
          else
            candidate = normalize_path(candidate)
          end
          if candidate:match("%.tsx$") and not seen[candidate] then
            seen[candidate] = true
            files[#files + 1] = candidate
          end
        end
      end
      proc:close()
      if #files > 0 then break end
    end
  end

  table.sort(files)
  return files
end

local function load_chunk(content, chunkname)
  local load_fn = loadstring or load
  local chunk, err = load_fn(content, "@" .. chunkname)
  if not chunk then return nil, err end
  local ok, result = pcall(chunk)
  if not ok then return nil, result end
  return result
end

-- Read the project's configured tile size from developer/config/tile_settings.lua,
-- deriving the project root from a map's own path (maps live at
-- <root>/developer/assets/tiled/maps/<name>.lua). Returns { w, h } or nil.
local function read_project_tile_size(map_path)
  if not map_path then return nil end
  local p = tostring(map_path):gsub("\\", "/")
  local root = p:match("^(.*)/developer/assets/tiled/maps/[^/]+$")
  if not root or root == "" then return nil end
  local content = read_file(root .. "/developer/config/tile_settings.lua")
  if not content then return nil end
  local w = tonumber(content:match("width%s*=%s*(%d+)"))
  local h = tonumber(content:match("height%s*=%s*(%d+)")) or w
  if w and w > 0 and h and h > 0 then return { w = w, h = h } end
  return nil
end

-- List .lua files under maps_dir without depending on lfs (so this works in
-- the headless editor, plain Lua 5.1, and the Defold runtime).
local function list_lua_files(maps_dir)
  local files = {}

  local bridge_files = list_bridge_files(maps_dir, "%.lua$")
  if bridge_files then
    return bridge_files
  end

  -- Try popen-based directory listing first; it is available in every
  -- environment we care about and avoids extra dependencies.
  local cmd
  if is_windows() then
    cmd = string.format('cmd /c dir /b /a-d "%s" 2>nul', maps_dir:gsub("/", "\\"))
  else
    cmd = string.format('ls -1 "%s" 2>/dev/null', maps_dir)
  end
  if io and io.popen then
    local ok_proc, proc = pcall(io.popen, cmd)
    if ok_proc and proc then
      for line in proc:lines() do
        if line ~= "" and line:match("%.lua$") then
          files[#files + 1] = line
        end
      end
      proc:close()
    end
  end

  table.sort(files)
  return files
end

-- Build the whitelist of allowed object `type` values. Pulls from
-- spawner_registry's canonical build-time list when available so that adding
-- a new spawner type does not require updating two files.
local function build_object_type_whitelist()
  local whitelist = {}
  local ok, registry = pcall(require, "mvtk.tiled.spawner_registry")
  if ok and registry and registry.get_canonical_build_time_skip_types then
    for _, t in ipairs(registry.get_canonical_build_time_skip_types() or {}) do
      whitelist[t] = true
    end
  end
  return whitelist, ok and registry or nil
end

-- The build pipeline (hooks/core/tiled_objects.lua) infers a type for blank
-- objects from their name/class/properties before spawning. The validator
-- mirrors that behaviour so a passing validation matches what the build
-- pipeline can actually spawn.
local function load_resolver()
  local ok_to, tiled_objects = pcall(require, "hooks.core.tiled_objects")
  if not ok_to or type(tiled_objects) ~= "table"
      or type(tiled_objects.resolve_object_type) ~= "function" then
    return nil, nil
  end
  -- Known-types set used by resolve_object_type. Prefer the same path the
  -- editor uses (object_spawner.handlers); fall back to the spawner_registry
  -- whitelist otherwise.
  local known_types = {}
  local ok_load, set = pcall(tiled_objects.load_object_type_set)
  if ok_load and type(set) == "table" then
    for k in pairs(set) do known_types[k] = true end
  else
    local wl = build_object_type_whitelist()
    for k in pairs(wl) do known_types[k] = true end
  end
  return tiled_objects, known_types
end

-- Walk an object's `properties` (table OR array form) and collect a flat
-- map of name -> value, unwrapping {value=..} records as the build pipeline
-- does. Used for template-version scanning.
local function flatten_properties(props)
  return PropertyFlattener.flatten(props)
end

-- Load the same pure slot resolver used by the enemy runtime, plus the
-- creator-owned enemy presets. Keeping this lazy means ordinary map schema
-- validation can still explain a missing optional module instead of failing
-- at require time.
local enemy_authoring_context
local ENEMY_AUTHORING_LOAD_ERROR =
  "enemy behavior resolver, property normalizer, or developer enemy types could not be loaded"
local function load_enemy_authoring_context()
  if enemy_authoring_context ~= nil then
    return enemy_authoring_context ~= false and enemy_authoring_context or nil
  end

  local ok_resolver, resolver = pcall(require, "mvtk.enemies.enemy_behavior_resolver")
  local ok_overrides, overrides = pcall(require, "mvtk.enemies.enemy_overrides")
  local ok_types, enemy_types = pcall(require, "developer.config.enemy_types")
  if not ok_resolver or type(resolver) ~= "table" or type(resolver.resolve) ~= "function"
      or not ok_overrides or type(overrides) ~= "table"
      or type(overrides.flatten_tiled_properties) ~= "function"
      or not ok_types or type(enemy_types) ~= "table" then
    enemy_authoring_context = false
    return nil
  end

  local ok_overlay, overlay = pcall(require, "mvtk.enemies.enemy_type_overlay")
  local ok_skins, skins = pcall(require, "developer.config.enemy_skins_generated")
  enemy_authoring_context = {
    resolver = resolver,
    overrides = overrides,
    enemy_types = enemy_types,
    overlay = ok_overlay and overlay or nil,
    skins = ok_skins and skins or nil,
    cache = {},
  }
  return enemy_authoring_context
end

-- Prepare & Check rewrites the synced-skin manifest (Sync Enemy Art) and may
-- bring in new presets between validation runs, while the editor keeps this
-- module loaded across commands. Each directory run starts from the files.
local ENEMY_CONFIG_MODULES = { "developer.config.enemy_types", "developer.config.enemy_skins_generated" }
local function refresh_enemy_authoring_context()
  enemy_authoring_context = nil
  for _, name in ipairs(ENEMY_CONFIG_MODULES) do
    package.loaded[name] = nil
  end
end

local function resolve_enemy_authoring_config(context, enemy_type)
  if not context or not enemy_type or enemy_type == "" then return nil end
  local config = context.enemy_types[enemy_type]
  if type(config) == "table" then return config end
  if context.overlay and type(context.overlay.resolve) == "function" then
    return context.overlay.resolve(enemy_type, context.enemy_types, context.skins, {
      cache = context.cache,
    })
  end
  return nil
end

local function inspect_enemy_authoring(object)
  local context = load_enemy_authoring_context()
  if not context then
    return nil, ENEMY_AUTHORING_LOAD_ERROR
  end

  local props = context.overrides.flatten_tiled_properties(
    object and object.properties)
  local skin = tostring(props.skin or ""):match("^%s*(.-)%s*$")
  local skins = context.skins and context.skins.skins or {}
  if skin ~= "" and not skins[skin] then
    return nil, string.format("exported skin '%s' is not synced. Export the room from Tiled again, then Prepare & Check", skin), props, true
  end
  local enemy_type = tostring(props.enemy_type or ""):match("^%s*(.-)%s*$")
  if enemy_type == "" then
    return nil, "enemy_type is empty", props
  end
  local config = resolve_enemy_authoring_config(context, enemy_type)
  if type(config) ~= "table" then
    return nil, string.format("enemy_type '%s' has no preset or synced-skin fallback", enemy_type), props
  end

  local result = context.resolver.resolve({
    behavior = config.behavior,
    grounded_movement = config.grounded_movement == true,
    movement = props.movement,
    attack_pattern = props.attack_pattern,
    attack_pattern2 = props.attack_pattern2,
  })
  return {
    enemy_type = enemy_type,
    config = config,
    properties = props,
    result = result,
  }, nil, props
end

local function behavior_list_text(values)
  if type(values) ~= "table" or #values == 0 then return "none" end
  return table.concat(values, ",")
end

local function warn_unusually_low_enemy_speeds(props, context_text, warn)
  for _, field in ipairs({ "chase_speed", "charge_speed" }) do
    local value = tonumber(type(props) == "table" and props[field] or nil)
    if value and value > 0 and value <= 10 then
      warn(string.format(
        "%s authored %s=%s px/s is unusually low and may look stationary; "
          .. "use the inherited/default sentinel or choose a value above 10 px/s",
        context_text, field, tostring(value)))
    end
  end
end

local function validate_room_music_path(map, map_path, err)
  local project_root = project_root_from_map_path(map_path)
  if not project_root or type(map) ~= "table" then return end

  local properties = flatten_properties(map.properties)
  local property_name, source = nil, nil
  for _, name in ipairs(MAP_MUSIC_PROPERTY_NAMES) do
    local value = properties[name]
    if value ~= nil then
      value = tostring(value):match("^%s*(.-)%s*$")
      if value ~= "" then
        property_name, source = name, value
        break
      end
    end
  end
  if not source then return end

  local music_path = is_abs(source)
      and normalize_path(source)
      or join_path(dirname(map_path), source)
  if is_abs(source) or not path_is_within(music_path, project_root) then
    err(string.format(
      "room music property '%s' references '%s' using an absolute path or a path outside the project root; re-export this room from Tiled with the MVTK export action so music is localized into developer/assets/music",
      tostring(property_name),
      tostring(source)))
  end
end

local function load_template_versions()
  local ok, tv = pcall(require, "mvtk.tiled.template_versions")
  if ok and type(tv) == "table" then return tv end
  return nil
end

-- Recursively collect objectgroup objects from a layer tree (groups can nest).
local function collect_objects(layers, out, parent_offset_x, parent_offset_y, parent_visible)
  out = out or {}
  parent_offset_x = tonumber(parent_offset_x) or 0
  parent_offset_y = tonumber(parent_offset_y) or 0
  if parent_visible == nil then parent_visible = true end
  for _, layer in ipairs(layers or {}) do
    local lt = layer.type
    local offset_x = parent_offset_x + (tonumber(layer.offsetx) or 0)
    local offset_y = parent_offset_y + (tonumber(layer.offsety) or 0)
    local visible = parent_visible and layer.visible ~= false
    if lt == "objectgroup" then
      for _, obj in ipairs(layer.objects or {}) do
        out[#out + 1] = {
          layer = layer.name or "<unnamed>",
          object = obj,
          offset_x = offset_x,
          offset_y = offset_y,
          visible = visible,
        }
      end
    elseif lt == "group" then
      collect_objects(layer.layers, out, offset_x, offset_y, visible)
    end
    -- tilelayer / imagelayer / unknown -> skipped
  end
  return out
end

-- Recursively collect visual/terrain tile layers (groups can nest). Grapple
-- paint is bake metadata: tile identity supplies neither art nor collision.
local function collect_tile_layers(layers, out)
  out = out or {}
  for _, layer in ipairs(layers or {}) do
    if type(layer) == "table" then
      local lt = layer.type
      if lt == "tilelayer" and TilemapRegen.normalize_layer_name(layer.name) ~= "grapple" then
        out[#out + 1] = layer
      elseif lt == "group" then
        collect_tile_layers(layer.layers, out)
      end
    end
  end
  return out
end

-- Recursively collect image layers from a layer tree. Tiled permits image
-- layers inside groups, so validating only the map's top-level layer list
-- would allow an external dependency to hide in a nested group.
local function collect_image_layers(layers, out)
  out = out or {}
  for _, layer in ipairs(layers or {}) do
    if type(layer) == "table" then
      local lt = layer.type
      if lt == "imagelayer" then
        out[#out + 1] = layer
      elseif type(layer.layers) == "table" then
        collect_image_layers(layer.layers, out)
      end
    end
  end
  return out
end

local function format_tileset_usage_counts(counts)
  local names = {}
  for name in pairs(counts or {}) do
    names[#names + 1] = name
  end
  table.sort(names)

  local parts = {}
  for _, name in ipairs(names) do
    local count = tonumber(counts[name]) or 0
    parts[#parts + 1] = string.format("%d tile(s) from '%s'", count, name)
  end
  return table.concat(parts, ", ")
end

local function parse_xml_attrs(attr_text)
  local attrs = {}
  if type(attr_text) ~= "string" then return attrs end
  for name, _, value in attr_text:gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do
    attrs[name] = value
  end
  return attrs
end

local function format_tile_id_counts(counts)
  local ids = {}
  local total = 0
  for id, count in pairs(counts or {}) do
    ids[#ids + 1] = tonumber(id) or id
    total = total + (tonumber(count) or 0)
  end
  table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
  local parts = {}
  for i = 1, math.min(#ids, 16) do
    local id = ids[i]
    parts[#parts + 1] = tostring(id) .. "x" .. tostring(counts[id])
  end
  if #ids > 16 then
    parts[#parts + 1] = "..." .. tostring(#ids - 16) .. " more"
  end
  return table.concat(parts, ", ") .. " (" .. tostring(total) .. " cell(s))"
end

local function collect_primary_used_tile_ids(map, primary_tileset)
  local counts = {}
  if type(primary_tileset) ~= "table" then
    return counts
  end
  local firstgid, lastgid = TilesetSelection.get_tileset_gid_range(
    map,
    primary_tileset,
    TilesetSelection.TILED_GID_MASK
  )
  for _, layer in ipairs(collect_tile_layers(map.layers)) do
    if type(layer.data) == "table" then
      for _, raw_gid in ipairs(layer.data) do
        local gid = TilesetSelection.decode_gid_value(raw_gid)
        if gid > 0 and gid >= firstgid and gid <= lastgid then
          local local_id = gid - firstgid
          counts[local_id] = (counts[local_id] or 0) + 1
        end
      end
    end
  end
  return counts
end

local function parse_tsx_collision_ids(tsx_content)
  local ids = {}
  if type(tsx_content) ~= "string" then return ids end
  for tile_block in tsx_content:gmatch("<tile%s+.-</tile>") do
    local attrs = parse_xml_attrs(tile_block:match("<tile%s+([^>]*)>") or "")
    local tile_id = tonumber(attrs.id)
    if tile_id ~= nil then
      local shapes = TileCollision.parse_tile_collision_shapes(tile_block)
      if shapes then
        ids[tile_id] = true
      end
    end
  end
  return ids
end

local function collect_tileset_collision_ids(tileset, tsx_content)
  local ids = {}
  if type(tileset) == "table" and type(tileset.tiles) == "table" then
    for _, tile in ipairs(tileset.tiles) do
      local tile_id = tonumber(tile and tile.id)
      if tile_id ~= nil then
        local shapes = TileCollision.parse_tile_collision_shapes_from_objectgroup(tile.objectGroup)
        if shapes then
          ids[tile_id] = true
        end
      end
    end
  end
  for tile_id in pairs(parse_tsx_collision_ids(tsx_content)) do
    ids[tile_id] = true
  end
  return ids
end

local function parse_tsx_image_basename(tsx_content)
  if type(tsx_content) ~= "string" then return nil end
  local image_attr_text = tsx_content:match("<image%s+([^>/]-)/>") or tsx_content:match("<image%s+([^>]*)>")
  if not image_attr_text then return nil end
  local attrs = parse_xml_attrs(image_attr_text)
  if attrs.source and attrs.source ~= "" then
    return basename(attrs.source)
  end
  return nil
end

local function validate_tsx_image_paths(tsx_path, tsx_content, map_path, tileset_name, err)
  local project_root = project_root_from_map_path(map_path)
  if not project_root or type(tsx_content) ~= "string" then return end

  for attr_text in tsx_content:gmatch("<image%s+([^>]*)>") do
    local attrs = parse_xml_attrs(attr_text)
    local source = attrs.source
    if source and source ~= "" then
      local image_path = is_abs(source)
          and normalize_path(source)
          or join_path(dirname(tsx_path), source)
      if not path_is_within(image_path, project_root) then
        err(string.format(
          "tileset '%s' file '%s' references image '%s' outside the project root; re-export this room from Tiled with the MVTK export action so tileset images are localized automatically",
          tostring(tileset_name or "<unnamed>"),
          tostring(tsx_path),
          tostring(source)))
      elseif not read_file(image_path) then
        err(string.format(
          "tileset '%s' file '%s' references missing project-local image '%s' at '%s'; re-export this room from Tiled with the MVTK export action, and fix the source TSX image reference if it remains missing",
          tostring(tileset_name or "<unnamed>"),
          tostring(tsx_path),
          tostring(source),
          tostring(image_path)))
      end
    end
  end
end

local function validate_image_layer_paths(map, map_path, err)
  local project_root = project_root_from_map_path(map_path)
  if not project_root or type(map) ~= "table" then return end

  local map_dir = dirname(map_path)
  for _, layer in ipairs(collect_image_layers(map.layers)) do
    local source = layer.image
    if type(source) == "string" and source ~= "" then
      local image_path = is_abs(source)
          and normalize_path(source)
          or join_path(map_dir, source)
      if not path_is_within(image_path, project_root) then
        err(string.format(
          "image layer '%s' references image '%s' outside the project root; re-export this room from Tiled with the MVTK export action so the image is localized into the project",
          tostring(layer.name or "<unnamed>"),
          tostring(source)))
      elseif not read_file(image_path) then
        err(string.format(
          "image layer '%s' references missing project-local image '%s' at '%s'; re-export this room from Tiled with the MVTK export action",
          tostring(layer.name or "<unnamed>"),
          tostring(source),
          tostring(image_path)))
      end
    end
  end
end

local function duplicate_key(a, b, image_name)
  a, b = tostring(a or ""), tostring(b or "")
  if a > b then a, b = b, a end
  return a .. "|" .. b .. "|" .. tostring(image_name or ""):lower()
end

local function validate_tileset_tsx_and_collision(map, map_path, err, warn, info)
  if type(map.tilesets) ~= "table" then
    return
  end
  local map_dir = dirname(map_path)
  local primary_tileset = TilesetSelection.select_primary_tileset(map)
  local primary_ref = tostring(primary_tileset and (primary_tileset.filename or primary_tileset.source) or "")
  local primary_tsx_path = nil
  local primary_tsx_content = nil
  local image_seen = {}
  local resolved_tsx_paths = {}
  local scanned_dirs = {}
  local duplicate_warned = {}

  for _, tileset in ipairs(map.tilesets) do
    if type(tileset) == "table" then
      local ref = tileset.filename or tileset.source
      local tsx_path, tsx_content, resolution = nil, nil, nil
      if ref and ref ~= "" then
        tsx_path, tsx_content, resolution = resolve_file(ref, map_dir, map_path)
        if resolution and resolution.external_ref then
          err(string.format(
            "tileset '%s' references .tsx '%s' outside the project root from map export path '%s'; re-export this room from Tiled with the MVTK export action so the tileset is localized automatically",
            tostring(tileset.name or "<unnamed>"),
            tostring(ref),
            tostring(map_path)))
        end
        if not tsx_path then
          warn(string.format(
            "tileset '%s' references .tsx '%s' but it could not be resolved from map export path '%s'",
            tostring(tileset.name or "<unnamed>"),
            tostring(ref),
            tostring(map_path)))
        else
          resolved_tsx_paths[tsx_path] = true
          validate_tsx_image_paths(
            tsx_path,
            tsx_content,
            map_path,
            tileset.name,
            err)
          if resolution and resolution.project_local and resolution.external_ref then
            info(string.format(
              "tileset '%s' references external .tsx '%s'; using project-local copy '%s'",
              tostring(tileset.name or "<unnamed>"),
              tostring(ref),
              tostring(tsx_path)))
          end
        end
      end
      if tileset == primary_tileset then
        primary_tsx_path = tsx_path
        primary_tsx_content = tsx_content
      end

      local image_name = nil
      if tileset.image and tileset.image ~= "" then
        image_name = basename(tileset.image)
      elseif tsx_content then
        image_name = parse_tsx_image_basename(tsx_content)
      end
      if image_name and image_name ~= "" and tsx_path then
        local key = image_name:lower()
        if image_seen[key] and image_seen[key] ~= tsx_path then
          local dup_key = duplicate_key(image_seen[key], tsx_path, image_name)
          if not duplicate_warned[dup_key] then
            duplicate_warned[dup_key] = true
            warn(string.format(
              "tilesets '%s' and '%s' both reference image basename '%s'; primary tilemap tileset uses '%s'",
              tostring(image_seen[key]),
              tostring(tsx_path),
              tostring(image_name),
              tostring(primary_tsx_path or primary_ref or "<inline>")))
          end
        else
          image_seen[key] = tsx_path
        end
      end
    end
  end

  -- Best-effort guard for the common trap where the map references one .tsx,
  -- but a sibling .tsx over the same PNG contains the user's saved edits.
  for tsx_path in pairs(resolved_tsx_paths) do
    local dir = dirname(tsx_path)
    if not scanned_dirs[dir] then
      scanned_dirs[dir] = true
      for _, sibling_path in ipairs(list_tsx_files(dir)) do
        if sibling_path ~= tsx_path and not resolved_tsx_paths[sibling_path] then
          local sibling_content = read_file(sibling_path)
          local image_name = parse_tsx_image_basename(sibling_content)
          local seen_path = image_name and image_seen[image_name:lower()] or nil
          if seen_path and seen_path ~= sibling_path then
            local dup_key = duplicate_key(seen_path, sibling_path, image_name)
            if not duplicate_warned[dup_key] then
              duplicate_warned[dup_key] = true
              warn(string.format(
                "tileset file '%s' and sibling '%s' both reference image basename '%s'; map uses '%s'. Check that Tile Collision Editor changes were saved to the tileset this map references.",
                tostring(seen_path),
                tostring(sibling_path),
                tostring(image_name),
                tostring(primary_tsx_path or primary_ref or "<inline>")))
            end
          end
        end
      end
    end
  end

  if type(primary_tileset) == "table" then
    local used_counts = collect_primary_used_tile_ids(map, primary_tileset)
    local collision_ids = collect_tileset_collision_ids(primary_tileset, primary_tsx_content)
    local missing = {}
    for tile_id, count in pairs(used_counts) do
      if not collision_ids[tile_id] then
        missing[tile_id] = count
      end
    end
    if next(missing) ~= nil then
      info(string.format(
        "primary tileset '%s' used tile ids without collision shapes: %s",
        tostring(primary_tileset.name or "<unnamed>"),
        format_tile_id_counts(missing)))
    end
  end
end

local function validate_tile_layer_tilesets(map, err)
  local primary_tileset = TilesetSelection.select_primary_tileset(map)
  if not primary_tileset then
    return
  end

  local primary_name = tostring(primary_tileset.name or "<unnamed>")
  local firstgid, lastgid = TilesetSelection.get_tileset_gid_range(
    map,
    primary_tileset,
    TilesetSelection.TILED_GID_MASK
  )

  for _, layer in ipairs(collect_tile_layers(map.layers)) do
    if type(layer.data) == "table" then
      local layer_name = tostring(layer.name or "<unnamed>")
      local layer_width = tonumber(layer.width) or tonumber(map.width) or 1
      if layer_width <= 0 then layer_width = 1 end

      local foreign_counts = {}
      local samples = {}

      for i, raw_gid in ipairs(layer.data) do
        local gid = TilesetSelection.decode_gid_value(raw_gid)
        if gid > 0 and (gid < firstgid or gid > lastgid) then
          local foreign_tileset = TilesetSelection.find_tileset_for_gid(map, gid)
          local foreign_name = tostring((foreign_tileset and foreign_tileset.name) or "<unknown>")
          foreign_counts[foreign_name] = (foreign_counts[foreign_name] or 0) + 1

          if #samples < 5 then
            local x = (i - 1) % layer_width
            local y = math.floor((i - 1) / layer_width)
            samples[#samples + 1] = string.format(
              "cell_x=%d cell_y=%d gid=%d tileset=%s",
              x,
              y,
              gid,
              foreign_name
            )
          end
        end
      end

      if next(foreign_counts) ~= nil then
        err(string.format(
          "layer '%s' uses %s outside primary tileset '%s' (GID range %d-%d). Defold tilemaps support one tilesource; move these tiles to object/background visuals, combine the tilesheets, or split the map into separate tilemaps. Samples: %s",
          layer_name,
          format_tileset_usage_counts(foreign_counts),
          primary_name,
          firstgid,
          lastgid,
          table.concat(samples, "; ")
        ))
      end
    end
  end
end

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

-- Validate a single map file. Returns ok (boolean), report (table).
-- The report contains:
--   { ok, errors = {}, warnings = {}, info = {}, path = ..., name = ... }
function M.validate_file(path, opts)
  opts = opts or {}
  local report = {
    path = path,
    name = path:match("([^/\\]+)$") or path,
    errors = {},
    warnings = {},
    info = {},
    ok = true,
  }

  local function err(msg)
    report.ok = false
    report.errors[#report.errors + 1] = msg
  end
  local invisible_warnings={}
  local function warn(msg)
    if msg:find("will be invisible",1,true) then
      local id=msg:match("object id=([^ ]+)")
      local key=msg:gsub("object id=[^ ]+","object ids=%%s")
      if id then
        local group=invisible_warnings[key]
        if group then
          group.ids[#group.ids+1]=id
          report.warnings[group.index]=key:gsub("%%s",table.concat(group.ids,","))
          return
        end
        invisible_warnings[key]={ids={id},index=#report.warnings+1}
      end
    end
    report.warnings[#report.warnings + 1] = msg
  end
  local function info(msg) report.info[#report.info + 1] = msg end

  local content, read_err = read_file(path)
  if not content then
    err("could not read file: " .. tostring(read_err))
    return false, report
  end

  local map, load_err = load_chunk(content, path)
  if not map then
    err("failed to load Lua: " .. tostring(load_err))
    return false, report
  end
  if type(map) ~= "table" then
    err("map did not return a table (got " .. type(map) .. ")")
    return false, report
  end

  local _, native_diagnostics = require("developer.tools.object_references").normalize(map, report.name:gsub("%.lua$", ""))
  for _,d in ipairs(native_diagnostics) do
    err(require("developer.tools.content_relationships").format_diagnostic(d))
  end

  -- Required top-level fields ------------------------------------------------
  for _, field in ipairs(REQUIRED_TOP_LEVEL) do
    if map[field] == nil then
      err("missing required top-level field: " .. field)
    end
  end

  -- Tile size sanity ---------------------------------------------------------
  local tw, th = tonumber(map.tilewidth), tonumber(map.tileheight)
  if tw and th and tw > 0 and th > 0 and tw ~= th then
    warn(string.format("non-square tile size %dx%d (most MVTK presets assume square tiles)", tw, th))
  end

  -- Tile size vs project setting: a map whose grid differs from the project
  -- tile size imports at the wrong scale. This is the #1 scaling mistake, so
  -- flag it at build time too (the Tiled exporter also warns at authoring time).
  local proj = read_project_tile_size(path)
  if proj and tw and th and (proj.w ~= tw or proj.h ~= th) then
    warn(string.format(
      "map tile size %dx%d differs from the project tile size %dx%d "
      .. "(developer/config/tile_settings.lua); rooms import at the wrong scale. "
      .. "Match the Tiled map and TSX tile dimensions to the imported art, then export and run Prepare & Check.", tw, th, proj.w, proj.h))
  end

  -- Layer shape --------------------------------------------------------------
  if type(map.layers) == "table" then
    for i, layer in ipairs(map.layers) do
      if type(layer) ~= "table" then
        err(string.format("layers[%d] is not a table", i))
      elseif not KNOWN_LAYER_TYPES[layer.type] then
        warn(string.format("layers[%d] (%s) has unknown layer type '%s'",
          i, tostring(layer.name), tostring(layer.type)))
      end
    end
  end

  -- Defold tilemaps can reference only one tilesource. Tiled maps may declare
  -- several tilesets for objects/background visuals. Visual/terrain tile cells
  -- must stay within the same primary range; grapple paint only tags geometry.
  validate_tile_layer_tilesets(map, err)
  validate_tileset_tsx_and_collision(map, path, err, warn, info)
  validate_image_layer_paths(map, path, err)
  validate_room_music_path(map, path, err)

  -- Object types ------------------------------------------------------------
  -- Reuse the build pipeline's resolver so blank `type` objects that are
  -- inferred from name/class/properties (the common authoring pattern) are
  -- accepted here exactly the same as during a real build.
  local resolver, known_types = load_resolver()
  local whitelist, registry = build_object_type_whitelist()
  if not resolver then
    err("hooks.core.tiled_objects is not loadable; cannot validate build-time object types or boss camera authority")
  elseif not registry then
    warn("mvtk.tiled.spawner_registry is not loadable; using the editor object-type resolver only")
  end

  local objects = type(map.layers) == "table" and collect_objects(map.layers) or {}
  -- An image object whose owner_ref selects a gameplay object draws it (see
  -- docs/TILED_OBJECT_ART.md), so that object is visible without painted tiles.
  -- Unowned object_art images (for example a painted room) are drawn like
  -- tiles, so an object inside one has art beneath it.
  local linked_art, painted = {}, {}
  for _, entry in ipairs(objects) do
    local o = entry.object
    local owner = VisualOwnership.property_value(o, "owner_ref")
    if type(owner) == "table" then owner = owner.id or owner.value end
    owner = tonumber(owner)
    if o.gid and owner and owner > 0 then
      linked_art[owner] = true
    elseif o.gid and (o.type == "object_art" or o.class == "object_art")
        and o.visible ~= false and entry.visible ~= false then
      -- Tile objects are anchored at their bottom-left corner.
      local x = (tonumber(o.x) or 0) + entry.offset_x
      local y = (tonumber(o.y) or 0) + entry.offset_y
      painted[#painted + 1] = { x, y - (tonumber(o.height) or 0), x + (tonumber(o.width) or 0), y }
    end
  end
  local function over_painted_art(entry)
    local o = entry.object
    local x0 = (tonumber(o.x) or 0) + entry.offset_x
    local y0 = (tonumber(o.y) or 0) + entry.offset_y
    local x1, y1 = x0 + (tonumber(o.width) or 0), y0 + (tonumber(o.height) or 0)
    for _, r in ipairs(painted) do
      if x0 < r[3] and r[1] < x1 and y0 < r[4] and r[2] < y1 then return true end
    end
    return false
  end
  local boss_arena_objects = {}
  local enemy_authoring_unavailable_reported = false
  for _, entry in ipairs(objects) do
    local obj = entry.object
    local is_helper_geometry = obj.polyline ~= nil or obj.polygon ~= nil
    -- Background visuals (tile-based GID objects on a "background"-named
    -- layer) are accepted by hooks/core/tiled_objects.lua and rewritten to
    -- type="background_visual" before spawn. Mirror that contract here so
    -- common scenery does not fail validation.
    local is_background_visual = false
    if resolver and type(resolver.is_background_visual_object_candidate) == "function" then
      local ok_bv, bv = pcall(resolver.is_background_visual_object_candidate, obj, entry.layer)
      is_background_visual = ok_bv and bv == true
    end
    local resolved, source
    if resolver then
      resolved, source = resolver.resolve_object_type(obj, known_types)
    end
    local is_retired = RetiredTypes.is_object_type(resolved)
    if resolved == "gate" then
      local props = flatten_properties(obj.properties)
      local warning = RetiredTypes.required_ability_warning(obj, report.name, props.required_ability)
      if warning then warn(warning) end
    end
    local _, property_collisions
    if resolved == "enemy" then
      local enemy_context = load_enemy_authoring_context()
      if enemy_context then
        _, property_collisions = enemy_context.overrides.flatten_tiled_properties(obj.properties)
      end
    end
    if property_collisions == nil then
      _, property_collisions = flatten_properties(obj.properties)
    end
    for _, collision in ipairs(property_collisions or {}) do
      if not collision.values_equal then
        local source_text = collision.kind == "group_group"
          and string.format("groups '%s' and '%s'", tostring(collision.existing_group), tostring(collision.group))
          or string.format("flat property and group '%s'", tostring(collision.group))
        warn(string.format(
          "layer '%s' object id=%s property '%s' is authored in both %s; using %s value (%s)",
          tostring(entry.layer), tostring(obj.id), tostring(collision.field), source_text,
          tostring(collision.resolution), tostring(collision.reason)))
      end
    end
    if resolved == "enemy" then
      local inspection, inspection_error, authoring_props, invalid_skin = inspect_enemy_authoring(obj)
      local enemy_context = string.format(
        "layer '%s' enemy object id=%s",
        tostring(entry.layer), tostring(obj.id))
      warn_unusually_low_enemy_speeds(authoring_props, enemy_context, warn)
      if inspection then
        local effective = inspection.result or {}
        info(string.format(
          "layer '%s' enemy object id=%s enemy_type='%s' effective behavior: movement=%s; attacks=%s",
          tostring(entry.layer),
          tostring(obj.id),
          tostring(inspection.enemy_type),
          tostring(effective.movement or "none"),
          behavior_list_text(effective.attacks)))
        if inspection.config and inspection.config._synthesized_from
            and inspection.enemy_type ~= "default" then
          warn(string.format(
            "%s enemy_type='%s' has synced enemy art but no explicit matching preset in "
              .. "developer/config/enemy_types.lua; using fallback preset '%s'",
            enemy_context,
            tostring(inspection.enemy_type),
            tostring(inspection.config._synthesized_from)))
        end
        for _, conflict in ipairs(effective.conflicts or {}) do
          warn(string.format(
            "layer '%s' enemy object id=%s enemy_type='%s' behavior conflict: %s",
            tostring(entry.layer), tostring(obj.id), tostring(inspection.enemy_type), tostring(conflict)))
        end
        for _, unknown in ipairs(effective.unknown or {}) do
          warn(string.format(
            "layer '%s' enemy object id=%s enemy_type='%s' uses unknown behavior pattern '%s'",
            tostring(entry.layer), tostring(obj.id), tostring(inspection.enemy_type), tostring(unknown)))
        end
      elseif invalid_skin then
        -- Import Assets reports before Create Rooms syncs newly linked art
        -- (enemy_art_pending); Validate All repeats the check after the sync.
        if not opts.enemy_art_pending then
          err(string.format("%s: %s: %s", tostring(path), enemy_context, inspection_error))
        end
      elseif not enemy_authoring_unavailable_reported
          or inspection_error ~= ENEMY_AUTHORING_LOAD_ERROR then
        warn(string.format(
          "layer '%s' enemy object id=%s could not resolve effective behavior: %s",
          tostring(entry.layer), tostring(obj.id), tostring(inspection_error)))
        if inspection_error == ENEMY_AUTHORING_LOAD_ERROR then
          enemy_authoring_unavailable_reported = true
        end
      end
    end
    local authored_ownership = VisualOwnership.property_value(obj, VisualOwnership.PROPERTY)
    if not is_retired and authored_ownership ~= nil and not VisualOwnership.supports(resolved) then
      warn(string.format(
        "layer '%s' object id=%s type='%s': this object type bakes no Defold sprite; use_defold_sprite has no effect",
        entry.layer, tostring(obj.id), tostring(resolved or obj.type or "unknown")))
    elseif not is_retired and not is_background_visual and resolved and VisualOwnership.supports(resolved)
        and not VisualOwnership.uses_defold_sprite(obj, resolved)
        and obj.visible ~= false and entry.visible ~= false
        and not linked_art[tonumber(obj.id)]
        and not over_painted_art(entry)
        and not TileOccupancy.rect_has_visible_art_tile(map, obj, {
          offset_x = entry.offset_x,
          offset_y = entry.offset_y,
          room_id = report.name,
        }) then
      warn(string.format(
        "layer '%s' object id=%s type='%s' will be invisible: use_defold_sprite=false and nothing is drawn under it on a visible non-control tile layer",
        entry.layer, tostring(obj.id), tostring(resolved)))
    end
    if not is_background_visual and resolved == "boss_arena" and obj.visible ~= false then
      boss_arena_objects[#boss_arena_objects + 1] = entry
    end
    if is_retired then
      warn(RetiredTypes.warning(obj, report.name))
    elseif is_background_visual then
      -- ok (handled by build pipeline as background_visual)
    elseif resolved and source ~= "unknown_explicit" and (not known_types or known_types[resolved]) then
      -- ok (explicit or inferred match). Note: do not mutate obj.type; we
      -- only validate.
    elseif resolved and source == "unknown_explicit" then
      err(string.format("layer '%s' object id=%s has unknown type '%s' (not a registered spawner)",
        entry.layer, tostring(obj.id), tostring(resolved)))
    else
      local raw = obj.type
      if not raw or raw == "" then
        if is_helper_geometry then
          info(string.format("layer '%s' object id=%s is helper geometry (polyline/polygon); skipped",
            entry.layer, tostring(obj.id)))
        else
          err(string.format("layer '%s' object id=%s has no resolvable type (no class/name/properties match a spawner)",
            entry.layer, tostring(obj.id)))
        end
      elseif registry and not whitelist[raw] then
        err(string.format("layer '%s' object id=%s has unknown type '%s' (not in spawner registry)",
          entry.layer, tostring(obj.id), tostring(raw)))
      end
    end
  end

  local map_properties = flatten_properties(map.properties)
  local room_zone = tostring(map_properties.room_zone or "")
  if room_zone == "boss_arena" and #boss_arena_objects > 0 then
    for _, entry in ipairs(boss_arena_objects) do
      err(string.format(
        "map room_zone='boss_arena' conflicts with boss_arena object id=%s on layer '%s'; set room_zone='exploration' so the boss_arena object is the sole camera authority",
        tostring(entry.object and entry.object.id),
        tostring(entry.layer or "<unnamed>")
      ))
    end
  end

  -- Template version markers -------------------------------------------------
  -- Every Tiled template under tiled/templates/**/*.tx ships with an
  -- mvtk_template_version property which is inherited by exported objects.
  -- Compare each object's version against mvtk/tiled/template_versions.lua so
  -- a downgrade or a forgotten export bump is caught before bundling.
  local versions = load_template_versions()
  if versions and versions.is_supported then
    -- Map-level marker (optional).
    local map_marker = map_properties.mvtk_export_version or map_properties.mvtk_template_version
    if map_marker == nil then
      info("no mvtk_export_version map property (consider adding for future compatibility checks)")
    else
      info("mvtk_export_version=" .. tostring(map_marker))
      if not versions.is_supported(map_marker) then
        warn(string.format("map mvtk_export_version='%s' is not in template_versions.SUPPORTED",
          tostring(map_marker)))
      end
    end
    -- Per-object markers.
    for _, entry in ipairs(objects) do
      local obj = entry.object
      local op = flatten_properties(obj.properties)
      local marker = op.mvtk_template_version
      if marker ~= nil then
        if not versions.is_supported(marker) then
          err(string.format("layer '%s' object id=%s mvtk_template_version='%s' not supported (current=%s)",
            entry.layer, tostring(obj.id), tostring(marker), tostring(versions.CURRENT or "?")))
        end
      end
    end
  else
    info("mvtk.tiled.template_versions not loadable; template-version check skipped")
  end

  return report.ok, report
end

-- Validate every .lua export in maps_dir (default DEFAULT_MAPS_DIR).
-- Returns ok (boolean), summary (table). summary contains per-file reports plus
-- aggregate counts.
function M.validate_dir(maps_dir, opts)
  maps_dir = maps_dir or DEFAULT_MAPS_DIR
  opts = opts or {}
  refresh_enemy_authoring_context()

  local files = list_lua_files(maps_dir)
  local summary = {
    maps_dir = maps_dir,
    files = {},
    error_count = 0,
    warning_count = 0,
    info_count = 0,
    ok = true,
    spawner_services = nil,
  }

  if #files == 0 then
    summary.ok = false
    summary.empty = true
    return false, summary
  end

  -- Spawner contract: strict tooling-side check. Required services that fail
  -- to resolve are reported by name so authors know exactly what is wrong
  -- before the editor tries to bundle the project.
  local reg_ok, registry = pcall(require, "mvtk.tiled.spawner_registry")
  if reg_ok and registry and registry.verify_required_services then
    local services_ok, missing, errors = registry.verify_required_services()
    summary.spawner_services = {
      ok = services_ok,
      missing = missing or {},
      errors = errors or {},
    }
    if not services_ok then
      summary.ok = false
      summary.error_count = summary.error_count + #(missing or {}) + #(errors or {})
    end
  end

  for _, name in ipairs(files) do
    local sep = (maps_dir:sub(-1) == "/" or maps_dir:sub(-1) == "\\") and "" or "/"
    local full = maps_dir .. sep .. name
    local ok, report = M.validate_file(full, opts)
    summary.files[#summary.files + 1] = report
    summary.error_count = summary.error_count + #report.errors
    summary.warning_count = summary.warning_count + #report.warnings
    summary.info_count = summary.info_count + #report.info
    if not ok then summary.ok = false end
  end

  if opts.relationships ~= false then
    local Relationships = require "developer.tools.content_relationships"
    local canonical = maps_dir:gsub("\\", "/"):gsub("/$", "")
    local project_root = canonical:match("^(.*)/developer/assets/tiled/maps$")
    if canonical == DEFAULT_MAPS_DIR then project_root = "." end
    local diagnostics
    if project_root then
      diagnostics = require("developer.tools.relationship_project").check({root=project_root, files=files}).diagnostics
    else
      local maps = {}
      for _,name in ipairs(files) do
        local path = maps_dir .. "/" .. name
        local content = read_file(path)
        local map = content and load_chunk(content,path)
        if type(map) == "table" then maps[name:gsub("%.lua$", "")] = {file=path,map=map} end
      end
      diagnostics = Relationships.validate(Relationships.build_index(maps))
    end
    local report = {name="authored relationships",path=maps_dir,errors={},warnings={},info={},ok=true}
    for _,d in ipairs(diagnostics) do
      local key = d.severity == "error" and "errors" or "warnings"
      report[key][#report[key]+1] = Relationships.format_diagnostic(d)
    end
    report.ok = #report.errors == 0
    summary.relationships = diagnostics
    summary.error_count = summary.error_count + #report.errors
    summary.warning_count = summary.warning_count + #report.warnings
    summary.ok = summary.ok and report.ok
  end

  return summary.ok, summary
end

-- Pretty-print a summary suitable for CLI / editor log output.
-- printer defaults to Lua's print.
function M.print_summary(summary, opts, printer)
  printer = printer or print
  opts = opts or {}
  local quick = opts.quick == true

  if summary.empty then
    printer(string.format("[TILED_EXPORT] ERROR no .lua maps found under %s", summary.maps_dir))
    return
  end

  if summary.spawner_services then
    local svc = summary.spawner_services
    if svc.ok then
      printer("[TILED_EXPORT] Spawner contract: OK (all required services resolve)")
    else
      printer("[TILED_EXPORT] Spawner contract: FAIL")
      for _, name in ipairs(svc.missing or {}) do
        printer("  MISSING SERVICE: " .. tostring(name))
      end
      for _, msg in ipairs(svc.errors or {}) do
        printer("  SERVICE ERROR:   " .. tostring(msg))
      end
    end
  end

  for _,d in ipairs(summary.relationships or {}) do
    printer("[TILED_EXPORT] " .. require("developer.tools.content_relationships").format_diagnostic(d))
  end

  for _, report in ipairs(summary.files) do
    if #report.errors > 0 then
      printer(string.format("[TILED_EXPORT] FAIL %s (%d error(s), %d warning(s), %d info)",
        report.name, #report.errors, #report.warnings, #report.info))
      for _, msg in ipairs(report.errors) do
        printer("  ERROR: " .. msg)
      end
      if not quick then
        for _, msg in ipairs(report.warnings) do
          printer("  WARN:  " .. msg)
        end
        for _, msg in ipairs(report.info) do
          printer("  INFO:  " .. msg)
        end
      end
    elseif (#report.warnings > 0 or #report.info > 0) and not quick then
      printer(string.format("[TILED_EXPORT] OK   %s (%d warning(s), %d info)",
        report.name, #report.warnings, #report.info))
      for _, msg in ipairs(report.warnings) do
        printer("  WARN:  " .. msg)
      end
      for _, msg in ipairs(report.info) do
        printer("  INFO:  " .. msg)
      end
    else
      printer(string.format("[TILED_EXPORT] OK   %s", report.name))
    end
  end

  printer(string.format("[TILED_EXPORT] Summary: %d file(s), %d error(s), %d warning(s), %d info",
    #summary.files, summary.error_count, summary.warning_count, summary.info_count or 0))
end

-- ----------------------------------------------------------------------------
-- CLI entry point
-- ----------------------------------------------------------------------------

-- Run the validator end-to-end and exit with the appropriate code. Used by
-- both the direct CLI (`lua tools/validate_tiled_export.lua`) and the editor
-- "Validate All" hook (hooks/core/validation.lua), which loads this file as a
-- chunk rather than via `require` -- so we cannot rely on the script being
-- the program entry point. Calling run_cli() unconditionally at module load
-- time keeps the two paths in sync.
function M.run_cli(args)
  args = args or arg or {}
  local quick = false
  local explicit_path = nil
  for _, a in ipairs(args) do
    if a == "--quick" then quick = true
    elseif type(a) == "string" and a:sub(1, 2) ~= "--" then
      explicit_path = a
    end
  end

  if explicit_path then
    local ok, report = M.validate_file(explicit_path)
    M.print_summary({ files = { report }, error_count = #report.errors,
      warning_count = #report.warnings, info_count = #report.info,
      ok = ok, maps_dir = explicit_path }, { quick = quick })
    os.exit(ok and 0 or 1)
  end

  local ok, summary = M.validate_dir(nil, { quick = quick })
  M.print_summary(summary, { quick = quick })
  if summary.empty then os.exit(2) end
  os.exit(ok and 0 or 1)
end

function M.is_require_module_name(value)
  return value == "tools.validate_tiled_export" or value == "validate_tiled_export"
end

-- Detect "loaded as a module via require" vs "executed as a script". Lua 5.1
-- passes direct script arguments through `...`, so only the exact module names
-- should suppress CLI execution; arbitrary args like "--quick" must still run.
local _module_name = ...
local LOADED_VIA_REQUIRE = M.is_require_module_name(_module_name)

if not LOADED_VIA_REQUIRE then
  M.run_cli(arg)
end

return M
