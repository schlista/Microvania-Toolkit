-- tools/validate_config.lua
-- Thin CLI driver that delegates to mvtk.core.config_validator.
--
-- Usage:
--   lua tools/validate_config.lua          -- run full schema validation
--   lua tools/validate_config.lua --quick  -- run quick (release-style) check
--   lua tools/validate_config.lua --legacy -- run legacy presence check
--
-- Exit codes:
--   0 = success
--   1 = validation errors found
--   2 = validator could not be loaded (e.g. missing schemas module)

local args = arg or {}
local mode = "full"
local allow_legacy_fallback = false
for _, a in ipairs(args) do
    if a == "--quick" then mode = "quick"
    elseif a == "--legacy" then mode = "legacy"
    elseif a == "--allow-legacy-fallback" then allow_legacy_fallback = true
    end
end

-- Legacy presence-only fallback (preserves the previous CLI behaviour
-- for environments where the schema-based validator cannot run).
local function run_legacy()
    local function check(require_path, required_keys)
        local ok, cfg = pcall(require, require_path)
        if not ok then
            print(string.format("[CONFIG] Missing or invalid: %s (%s)", require_path, cfg))
            return false
        end
        local all_ok = true
        for _, key in ipairs(required_keys or {}) do
            if cfg[key] == nil then
                print(string.format("[CONFIG] %s missing key '%s'", require_path, key))
                all_ok = false
            end
        end
        return all_ok
    end

    local checks = {
        { path = "developer.config.difficulty_settings", keys = { "profiles" } },
        { path = "developer.config.localization",        keys = { "locales" } },
        { path = "developer.config.ambient_zones",       keys = { "zones" } },
        { path = "developer.config.tutorial_popups",     keys = { "popups" } },
    }

    local ok = true
    for _, item in ipairs(checks) do
        ok = check(item.path, item.keys) and ok
    end

    if not ok then
        os.exit(1)
    end

    print("Config validation complete: OK (legacy)")
end

-- Always enforce the camera/GUI design-size contract, including quick and
-- legacy invocations. game.project is read only by this desktop CLI driver.
local project_file = io.open("game.project", "rb")
if not project_file then
    print("[CONFIG] Cannot read game.project to validate the display size.")
    os.exit(1)
end
local project_text = project_file:read("*a")
project_file:close()
local config_ok, game_config = pcall(require, "developer.config.game_config")
if not config_ok then
    print("[CONFIG] Cannot load developer.config.game_config: " .. tostring(game_config))
    os.exit(1)
end
local display_errors = require("mvtk.core.display_size").validate(game_config, project_text)
if #display_errors > 0 then
    for _, message in ipairs(display_errors) do print("[CONFIG] " .. message) end
    os.exit(1)
end

if mode == "legacy" then
    run_legacy()
    return
end

local ok, Validator = pcall(require, "mvtk.core.config_validator")
if not ok or type(Validator) ~= "table" then
    print("[CONFIG] Failed to load mvtk.core.config_validator: " .. tostring(Validator))
    if allow_legacy_fallback then
        print("[CONFIG] --allow-legacy-fallback set; running legacy presence check.")
        run_legacy()
        return
    end
    print("[CONFIG] Refusing to run silently with a broken schema validator.")
    print("[CONFIG] Pass --allow-legacy-fallback to opt in, or --legacy for explicit legacy mode.")
    os.exit(2)
end

if mode == "quick" then
    if Validator.validate_quick and Validator.validate_quick() then
        print("Config validation complete: OK (quick)")
        os.exit(0)
    else
        os.exit(1)
    end
end

if not Validator.validate_all_configs then
    print("[CONFIG] mvtk.core.config_validator missing validate_all_configs()")
    os.exit(2)
end

local success = Validator.validate_all_configs()
if success then
    print("Config validation complete: OK")
    os.exit(0)
else
    os.exit(1)
end
