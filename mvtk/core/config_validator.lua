-- mvtk/core/config_validator.lua
-- Validates configuration files against schemas
-- Provides helpful error messages for developers

local Schemas = require "mvtk.core.config_schemas"

local M = {}


-- Pure shared check; runtime callers supply text, never access game.project.
M.validate_display_size = require("mvtk.core.display_size").validate

-- ANSI color codes for terminal output (if supported)
local COLOR = {
  RED = "\27[31m",
  GREEN = "\27[32m",
  YELLOW = "\27[33m",
  BLUE = "\27[34m",
  MAGENTA = "\27[35m",
  CYAN = "\27[36m",
  RESET = "\27[0m",
  BOLD = "\27[1m",
}

-- Check if running in environment that supports colors
local SUPPORTS_COLOR = (sys and sys.get_sys_info and sys.get_sys_info().system_name ~= "HTML5")

-- Format colored text
local function color(text, col)
  if SUPPORTS_COLOR then
    return col .. text .. COLOR.RESET
  else
    return text
  end
end

-- Format error message box
local function format_error_box(title, errors)
  local lines = {}
  table.insert(lines, "")
  table.insert(lines, color("╔═══════════════════════════════════════════════════════════╗", COLOR.RED))
  table.insert(lines, color("║ " .. title .. string.rep(" ", 57 - #title) .. " ║", COLOR.RED))
  table.insert(lines, color("╚═══════════════════════════════════════════════════════════╝", COLOR.RED))

  for _, err in ipairs(errors) do
    table.insert(lines, color("  ❌ " .. err, COLOR.RED))
  end

  table.insert(lines, "")
  return table.concat(lines, "\n")
end

-- Format warning message box
local function format_warning_box(title, warnings)
  local lines = {}
  table.insert(lines, "")
  table.insert(lines, color("╔═══════════════════════════════════════════════════════════╗", COLOR.YELLOW))
  table.insert(lines, color("║ " .. title .. string.rep(" ", 57 - #title) .. " ║", COLOR.YELLOW))
  table.insert(lines, color("╚═══════════════════════════════════════════════════════════╝", COLOR.YELLOW))

  for _, warn in ipairs(warnings) do
    table.insert(lines, color("  ⚠️  " .. warn, COLOR.YELLOW))
  end

  table.insert(lines, "")
  return table.concat(lines, "\n")
end

-- Format success message
local function format_success(message)
  return color("✅ " .. message, COLOR.GREEN)
end

-- Validate a config table against a schema
function M.validate_config(config, schema)
  local errors = {}
  local warnings = {}

  if not config then
    table.insert(errors, "Config is nil or missing")
    return errors, warnings
  end

  if type(config) ~= "table" then
    table.insert(errors, "Config must be a table, got " .. type(config))
    return errors, warnings
  end

  local function validate_table_fields(tbl, required_fields, optional_fields, context)
    context = context or "config"
    if required_fields then
      for field_name, field_schema in pairs(required_fields) do
        local value = tbl[field_name]
        if value == nil then
          local type_desc = Schemas.get_type_description(field_schema)
          table.insert(errors, string.format(
            "%s: Missing required field '%s' (expected %s)",
            context, field_name, type_desc
          ))
        else
          local field_errors = Schemas.validate_field(value, field_schema, field_name)
          for _, err in ipairs(field_errors) do
            table.insert(errors, context .. ": " .. err)
          end
        end
      end
    end

    if optional_fields then
      for field_name, field_schema in pairs(optional_fields) do
        local value = tbl[field_name]
        if value ~= nil then
          local field_errors = Schemas.validate_field(value, field_schema, field_name)
          for _, err in ipairs(field_errors) do
            table.insert(errors, context .. ": " .. err)
          end
        end
      end
    end
  end

  -- Check required fields
  validate_table_fields(config, schema.required, schema.optional, schema.name or "config")

  -- Validate entry tables (map-style configs)
  if schema.entries and type(config) == "table" then
    for key, entry in pairs(config) do
      if key ~= "M" and key ~= "_VERSION" then
        if type(entry) ~= "table" then
          table.insert(errors, string.format("%s: Entry '%s' must be a table (got %s)", schema.name or "config", tostring(key), type(entry)))
        else
          validate_table_fields(entry, schema.entries.required, schema.entries.optional, string.format("%s[%s]", schema.name or "config", tostring(key)))
          -- Unknown field warnings for entries
          if not schema.entries.allow_unknown then
            for field_name, _ in pairs(entry) do
              local known = (schema.entries.required and schema.entries.required[field_name]) or (schema.entries.optional and schema.entries.optional[field_name])
              if not known then
                table.insert(warnings, string.format("%s[%s]: Unknown field '%s'", schema.name or "config", tostring(key), tostring(field_name)))
              end
            end
          end
        end
      end
    end
  end

  -- Check for unknown fields (warnings, not errors) only when not using entries
  -- Schemas may opt out with allow_unknown = true (the config still validates
  -- the known required/optional fields, but extra fields are silently ignored).
  if not schema.entries and not schema.allow_unknown then
    for field_name, _ in pairs(config) do
      local is_known = false

      if schema.required and schema.required[field_name] then
        is_known = true
      end

      if schema.optional and schema.optional[field_name] then
        is_known = true
      end

      if not is_known and field_name ~= "M" and field_name ~= "_VERSION" then
        table.insert(warnings, string.format(
          "Unknown field '%s' (not in schema, may be ignored)",
          field_name
        ))
      end
    end
  end

  -- Custom validation hook
  if schema.custom_validate and type(schema.custom_validate) == "function" then
    local custom_errors, custom_warnings = schema.custom_validate(config)
    for _, err in ipairs(custom_errors or {}) do table.insert(errors, err) end
    for _, warn in ipairs(custom_warnings or {}) do table.insert(warnings, warn) end
  end

  return errors, warnings
end

-- Validate a config file by path
function M.validate_config_file(config_path, schema)
  print(color("Validating: " .. config_path, COLOR.CYAN))

  -- Try to load config
  local ok, config = pcall(require, config_path)

  if not ok then
    local errors = {
      string.format("Failed to load config file: %s", config_path),
      string.format("Error: %s", tostring(config)),
      "",
      "Possible causes:",
      "  • File does not exist",
      "  • Lua syntax error in file",
      "  • File path is incorrect",
      "",
      "Expected location: /" .. config_path:gsub("%.", "/") .. ".lua"
    }
    return false, errors, {}
  end

  -- Validate config against schema
  local errors, warnings = M.validate_config(config, schema)

  if #errors > 0 then
    return false, errors, warnings
  end

  return true, {}, warnings
end

-- ============================================================================
-- CROSS-REFERENCE VALIDATION
-- ============================================================================
-- Validates that references between config files are consistent:
--   - gate required_ability → valid ability ID
--   - room_enemies enemy types → valid enemy_types entries
--   - shop items → valid item IDs
--   - dialogue goto targets → valid dialogue IDs
function M.validate_cross_references()
  local errors = {}
  local warnings = {}

  -- Helper: safe require config
  local function safe_load(path)
    local ok, mod = pcall(require, path)
    if ok and type(mod) == "table" then return mod end
    return nil
  end

  -- 1) Collect valid ability IDs
  local abilities = safe_load("developer.config.abilities")
  local valid_abilities = {}
  if abilities then
    for id, _ in pairs(abilities) do
      if type(id) == "string" and id ~= "M" and id ~= "_VERSION" then
        valid_abilities[id] = true
      end
    end
  end

  -- 2) Collect valid enemy type IDs
  local enemy_types = safe_load("developer.config.enemy_types")
  local valid_enemies = {}
  if enemy_types then
    for id, _ in pairs(enemy_types) do
      if type(id) == "string" and id ~= "M" and id ~= "_VERSION" then
        valid_enemies[id] = true
      end
    end
  end

  -- 3) Collect valid item IDs
  local items = safe_load("developer.config.items")
  local valid_items = {}
  if items then
    for id, _ in pairs(items) do
      if type(id) == "string" and id ~= "M" and id ~= "_VERSION" then
        valid_items[id] = true
      end
    end
  end

  -- 4) Collect valid dialogue IDs
  local dialogues = safe_load("developer.config.narrative.dialogues")
  local valid_dialogues = {}
  if dialogues then
    for id, _ in pairs(dialogues) do
      if type(id) == "string" and id ~= "M" and id ~= "_VERSION" then
        valid_dialogues[id] = true
      end
    end
  end

  -- Cross-ref: gates.required_ability → abilities
  local gates = safe_load("developer.config.gates")
  if gates and next(valid_abilities) then
    for gate_id, gate in pairs(gates) do
      if type(gate) == "table" and gate.required_ability then
        if not valid_abilities[gate.required_ability] then
          table.insert(warnings, string.format(
            "gates[%s].required_ability '%s' not found in abilities config",
            tostring(gate_id), tostring(gate.required_ability)))
        end
      end
    end
  end

  -- Cross-ref: room_enemies → enemy_types
  local room_enemies = safe_load("developer.config.room_enemies")
  if room_enemies and next(valid_enemies) then
    for room_id, spawns in pairs(room_enemies) do
      if type(spawns) == "table" then
        for i, spawn in ipairs(spawns) do
          local etype = type(spawn) == "table" and (spawn.type or spawn.enemy_type) or nil
          if etype and not valid_enemies[etype] then
            table.insert(warnings, string.format(
              "room_enemies[%s][%d].type '%s' not found in enemy_types config",
              tostring(room_id), i, tostring(etype)))
          end
        end
      end
    end
  end

  -- Cross-ref: dialogue goto targets → dialogue IDs
  if dialogues and next(valid_dialogues) then
    for dlg_id, lines in pairs(dialogues) do
      if type(lines) == "table" then
        for i, line in ipairs(lines) do
          if type(line) == "table" then
            if line.next and not valid_dialogues[line.next] then
              table.insert(warnings, string.format(
                "dialogues[%s][%d].next '%s' not found in dialogues config",
                tostring(dlg_id), i, tostring(line.next)))
            end
            if line.choices and type(line.choices) == "table" then
              for ci, choice in ipairs(line.choices) do
                if type(choice) == "table" and choice["goto"] and not valid_dialogues[choice["goto"]] then
                  table.insert(warnings, string.format(
                    "dialogues[%s][%d].choices[%d].goto '%s' not found in dialogues config",
                    tostring(dlg_id), i, ci, tostring(choice["goto"])))
                end
              end
            end
          end
        end
      end
    end
  end

  return errors, warnings
end

-- Validate all known config files
-- Report mixed file units once per file; conversion is performed by its loader.
function M.player_units_conversion_infos(player, configs)
  local messages = {}
  local Scale = require "mvtk.player.player_scale"
  for _, kind in ipairs({ "combat_config", "combat_overrides", "player_art" }) do
    local config = configs and configs[kind]
    if config then
      local message = Scale.conversion_info(config, kind, player)
      if message then messages[#messages + 1] = message end
    end
  end
  return messages
end

function M.validate_all_configs()
  print("")
  print(color("═══════════════════════════════════════════════════════════", COLOR.BLUE))
  print(color("  CONFIG VALIDATION STARTING", COLOR.BOLD .. COLOR.BLUE))
  print(color("═══════════════════════════════════════════════════════════", COLOR.BLUE))
  print("")

  local results = {}
  local total_errors = 0
  local total_warnings = 0

  -- List of configs to validate
  -- Most configs are optional since runtime systems have fallbacks
  local configs_to_validate = {
    { path = "developer.config.display_settings", schema = Schemas.display_settings },
    { path = "developer.config.creator_settings", schema = Schemas.creator_settings },
    { path = "developer.config.player_art", schema = Schemas.player_art },
    { path = "developer.config.movement_test", schema = Schemas.movement_test },
    { path = "developer.config.persistence_settings", schema = Schemas.persistence_settings },
    { path = "developer.config.game_completion", schema = Schemas.game_completion },
    { path = "developer.config.save_migrations", schema = Schemas.save_migrations },
    { path = "developer.config.player_settings", schema = Schemas.player_settings },
    { path = "developer.config.combat_config", schema = Schemas.combat_config },
    { path = "developer.config.combat_overrides", schema = Schemas.combat_overrides },
    { path = "developer.config.player_actions", schema = Schemas.player_actions },
    { path = "developer.config.default_bindings", schema = Schemas.default_bindings },
    { path = "developer.config.debug_config", schema = Schemas.debug_config },
    { path = "developer.config.abilities", schema = Schemas.abilities, optional = true },
    -- Optional configs (don't error if missing - systems have fallbacks)
    { path = "developer.config.enemy_settings", schema = Schemas.enemy_settings, optional = true },
    { path = "developer.config.gameplay_constants", schema = Schemas.gameplay_constants, optional = true },
    { path = "developer.config.tiled_object_config", schema = Schemas.tiled_object_config, optional = true },
    -- Content configs - optional since systems handle missing gracefully
    { path = "developer.config.enemy_types", schema = Schemas.enemy_types, optional = true },
    { path = "developer.config.room_enemies", schema = Schemas.room_enemies, optional = true },
    { path = "developer.config.tile_settings", schema = Schemas.tile_settings },
    { path = "developer.config.collectible_types", schema = Schemas.collectible_types },
    { path = "developer.config.loot_tables", schema = Schemas.loot_tables, optional = true },
    { path = "developer.config.gates", schema = Schemas.gates, optional = true },
    { path = "developer.config.biomes", schema = Schemas.biomes, optional = true },
    { path = "developer.config.items", schema = Schemas.items, optional = true },
    { path = "developer.config.map_markers", schema = Schemas.map_markers, optional = true },
    -- Creator-facing Microvania configs with loose schemas: load + table shape,
    -- while runtime-specific fields remain open-ended for authoring flexibility.
    { path = "developer.config.ability_defaults", schema = Schemas.ability_defaults, optional = true },
    { path = "developer.config.gate_types", schema = Schemas.gate_types, optional = true },
    { path = "developer.config.hazard_types", schema = Schemas.hazard_types, optional = true },
    { path = "developer.config.secret_settings", schema = Schemas.secret_settings, optional = true },
    { path = "developer.config.secret_types", schema = Schemas.secret_types, optional = true },
    { path = "developer.config.secret_rooms", schema = Schemas.secret_rooms, optional = true },
    { path = "developer.config.tileset_mapping", schema = Schemas.tileset_mapping, optional = true },
    { path = "developer.config.rooms_config", schema = Schemas.rooms_config, optional = true },
    { path = "developer.config.stream_settings", schema = Schemas.stream_settings, optional = true },
    { path = "developer.config.sound_bank", schema = Schemas.sound_bank, optional = true },
    { path = "developer.config.ambience_tracks", schema = Schemas.ambience_tracks, optional = true },
    { path = "developer.config.ambient_zones", schema = Schemas.ambient_zones, optional = true },
    { path = "developer.config.hud_layout", schema = Schemas.hud_layout, optional = true },
    { path = "developer.config.ui_theme", schema = Schemas.ui_theme, optional = true },
    { path = "developer.config.settings_defaults", schema = Schemas.settings_defaults, optional = true },
    { path = "developer.config.game_config", schema = Schemas.game_config, optional = true },
    { path = "developer.config.narrative.dialogues", schema = Schemas.narrative_dialogues, optional = true },
  }

  for _, config_info in ipairs(configs_to_validate) do
    local success, errors, warnings = M.validate_config_file(config_info.path, config_info.schema)

    local result = {
      path = config_info.path,
      schema_name = config_info.schema.name,
      success = success,
      errors = errors,
      warnings = warnings,
      optional = config_info.optional or false,
    }

    table.insert(results, result)

    -- Count errors and warnings
    if not config_info.optional then
      total_errors = total_errors + #errors
    end
    total_warnings = total_warnings + #warnings

    -- Print result
    if success then
      if #warnings > 0 then
        print(color("  ⚠️  " .. config_info.schema.name .. " - OK with warnings", COLOR.YELLOW))
      else
        print(format_success(config_info.schema.name .. " - OK"))
      end
    else
      if config_info.optional then
        print(color("  ⚠️  " .. config_info.schema.name .. " - MISSING (optional)", COLOR.YELLOW))
      else
        print(color("  ❌ " .. config_info.schema.name .. " - FAILED", COLOR.RED))
      end
    end
  end

  local ok_player, player = pcall(require, "developer.config.player_settings")
  if ok_player then
    local configs = {}
    for _, kind in ipairs({ "combat_config", "combat_overrides", "player_art" }) do
      local ok, config = pcall(require, "developer.config." .. kind)
      if ok then configs[kind] = config end
    end
    for _, message in ipairs(M.player_units_conversion_infos(player, configs)) do
      print("[CONFIG INFO] " .. message)
    end
  end

  print("")
  print(color("═══════════════════════════════════════════════════════════", COLOR.BLUE))

  -- Print detailed errors and warnings
  for _, result in ipairs(results) do
    if #result.errors > 0 then
      print(format_error_box(
        "ERRORS in " .. result.schema_name,
        result.errors
      ))

      -- Provide helpful hints
      if result.path:match("player_settings") then
        print(color("💡 Hint:", COLOR.CYAN))
        print(color("   Check developer/config/player_settings.lua for missing or invalid fields", COLOR.CYAN))
        print(color("   See docs/CREATOR_WORKFLOW.html for configuration guidance", COLOR.CYAN))
        print("")
      end
    end

    if #result.warnings > 0 then
      print(format_warning_box(
        "WARNINGS in " .. result.schema_name,
        result.warnings
      ))
    end
  end

  -- Cross-reference validation (references between configs)
  local xref_errors, xref_warnings = M.validate_cross_references()
  if #xref_errors > 0 then
    total_errors = total_errors + #xref_errors
    print(format_error_box("CROSS-REFERENCE ERRORS", xref_errors))
  end
  if #xref_warnings > 0 then
    total_warnings = total_warnings + #xref_warnings
    print(format_warning_box("CROSS-REFERENCE WARNINGS", xref_warnings))
  end

  -- Summary
  print(color("═══════════════════════════════════════════════════════════", COLOR.BLUE))
  print(color("  VALIDATION SUMMARY", COLOR.BOLD .. COLOR.BLUE))
  print(color("═══════════════════════════════════════════════════════════", COLOR.BLUE))

  if total_errors == 0 and total_warnings == 0 then
    print(format_success("All configs validated successfully! 🎉"))
  elseif total_errors == 0 then
    print(color(string.format("✅ Validation passed with %d warnings", total_warnings), COLOR.YELLOW))
  else
    print(color(string.format("❌ Validation failed: %d errors, %d warnings", total_errors, total_warnings), COLOR.RED))
    print("")
    print(color("⛔ GAME START BLOCKED - Fix config errors above", COLOR.RED .. COLOR.BOLD))
  end

  print("")

  return total_errors == 0, results
end

-- Quick validation with simple output (for release builds)
function M.validate_quick()
  -- Only validate truly required configs - those without runtime fallbacks
  local configs_to_validate = {
    { path = "developer.config.display_settings", schema = Schemas.display_settings },
    { path = "developer.config.creator_settings", schema = Schemas.creator_settings },
    { path = "developer.config.player_art", schema = Schemas.player_art },
    { path = "developer.config.movement_test", schema = Schemas.movement_test },
    { path = "developer.config.persistence_settings", schema = Schemas.persistence_settings },
    { path = "developer.config.game_completion", schema = Schemas.game_completion },
    { path = "developer.config.save_migrations", schema = Schemas.save_migrations },
    { path = "developer.config.player_settings", schema = Schemas.player_settings },
    { path = "developer.config.player_actions", schema = Schemas.player_actions },
    { path = "developer.config.default_bindings", schema = Schemas.default_bindings },
    -- abilities is optional - ability_manager has fallbacks
  }

  -- Quick-check configs that are truly required (no fallbacks)
  local quick_extra = {
    { path = "developer.config.tile_settings", schema = Schemas.tile_settings },
    { path = "developer.config.collectible_types", schema = Schemas.collectible_types },
    -- items / shops are archived for the Microvania beta. enemy_types,
    -- Enemy and room definitions have runtime fallbacks.
  }

  for _, c in ipairs(quick_extra) do table.insert(configs_to_validate, c) end

  for _, config_info in ipairs(configs_to_validate) do
    local ok, config = pcall(require, config_info.path)
    if not ok then
      print("[CONFIG ERROR] Failed to load: " .. config_info.path)
      return false
    end

    local errors, _ = M.validate_config(config, config_info.schema)
    if #errors > 0 then
      print("[CONFIG ERROR] Invalid config: " .. config_info.path)
      for _, err in ipairs(errors) do
        print("  " .. err)
      end
      return false
    end
  end

  return true
end

-- Safe require with validation
function M.safe_require(module_path, schema)
  if not schema then
    -- No schema provided, just do normal require
    return require(module_path)
  end

  -- Load module
  local ok, module = pcall(require, module_path)
  if not ok then
    error(string.format(
      "Failed to load config: %s\nError: %s",
      module_path, tostring(module)
    ))
  end

  -- Validate
  local errors, warnings = M.validate_config(module, schema)

  if #errors > 0 then
    local error_msg = format_error_box(
      "CONFIG ERROR: " .. module_path,
      errors
    )
    error(error_msg)
  end

  if #warnings > 0 then
    print(format_warning_box(
      "CONFIG WARNINGS: " .. module_path,
      warnings
    ))
  end

  return module
end

return M
