-- Pure authoring contract shared by Game Settings, project writer and runtime.
-- Keys are editor control names; paths are the only persisted representation.
local M = { VERSION = 1, fields = {} }
-- Identity is edited alongside creator settings, but project_identity owns its
-- files. Keeping these controls separate prevents creator overrides from
-- accidentally acquiring game.project or persistence-settings fields.
M.identity_fields = {
    project_name = { key = "project_name", title = "Game name", type = "string",
        help = "The title shown in game.project and the exported game. Renaming it keeps the permanent save ID." },
    game_id = { key = "game_id", title = "Game ID", type = "string", read_only = true,
        help = "Permanent save identity, assigned on the first Save. Renaming the game does not change it." },
}
local AbilityConfig = require "developer.config.abilities"
local PlayerScale = require "mvtk.player.player_scale"
local OldPlayerUnits = require "mvtk.core.player_units_baseline"
local CreatorPixelPaths = require "mvtk.core.player_units_paths"
local Number = require "mvtk.editor.settings_number"

function M.copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = M.copy(v) end
    return out
end

function M.merge(dst, src)
    for k, v in pairs(src or {}) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            M.merge(dst[k], v)
        else dst[k] = v end
    end
    return dst
end

local function get(tbl, path)
    for part in path:gmatch("[^.]+") do
        if type(tbl) ~= "table" then return nil end
        tbl = tbl[tonumber(part) or part]
    end
    return tbl
end

local function put(tbl, path, value)
    local parts = {}
    for part in path:gmatch("[^.]+") do parts[#parts + 1] = tonumber(part) or part end
    for i = 1, #parts - 1 do
        local key = parts[i]
        if type(tbl[key]) ~= "table" then tbl[key] = {} end
        tbl = tbl[key]
    end
    tbl[parts[#parts]] = value
end

M.get = get
M.put = put

-- Value aliases belong to the same authoring control. Start unlocks only live
-- in abilities; runtime availability and invulnerability follow acquired abilities.
M.mirrors = {
    wall_climb_speed = { "player.wall_climb.speed" },
}

local function remove(tbl, path)
    local head, tail = path:match("^([^.]+)%.(.+)$")
    if not head then tbl[tonumber(path) or path] = nil; return end
    head=tonumber(head) or head
    if type(tbl[head]) ~= "table" then return end
    remove(tbl[head], tail)
    if next(tbl[head]) == nil then tbl[head] = nil end
end

function M.prune_legacy(doc)
    for _, ability in ipairs({ "slide", "air_dash", "wall_climb", "extended_jump", "glide" }) do
        remove(doc.overrides, "player." .. ability .. ".enabled")
    end
    for _, ability in ipairs({ "slide", "air_dash" }) do
        remove(doc.overrides, "player." .. ability .. ".iframes")
    end
    return doc
end

function M.reset(doc, key)
    local spec = assert(M.fields[key], "Unknown creator field: " .. tostring(key))
    remove(doc.overrides, spec.path)
    for _, path in ipairs(M.mirrors[key] or {}) do remove(doc.overrides, path) end
    return M.prune_legacy(doc)
end

function M.controls(overrides, baseline)
    local effective = M.merge(M.copy(baseline or {}), overrides or {})
    local controls = {}
    for key, spec in pairs(M.fields) do
        local value = get(effective, spec.path)
        if value == nil then value = spec.default end
        controls[key] = M.copy(value)
    end
    if controls.combo_chaining == false then controls.mixed_finishers = false end
    if controls.parry == false then controls.perfect_parry, controls.parry_counter = false, false end
    if controls.aerial_attacks == false then controls.aerial_juggle = false end
    return controls
end

-- Game Settings window titles are sentence case: "Swing Power" -> "Swing power".
-- Acronyms (HUD, FPS) and single letters (X, Y) keep their capitals.
local function sentence(text)
    local first = true
    return (tostring(text):gsub("%a[%w']*", function(word)
        if first then first = false; return word end
        if #word == 1 or word == word:upper() then return word end
        return word:lower()
    end))
end
local function field(key, path, kind, title, help, min, max, alias)
    M.fields[key] = { key = key, path = path, type = kind, title = title, help = help, min = min, max = max, alias = alias }
end
local function number(key, path, title, min, max, help, alias)
    field(key, path, "number", title, help, min, max, alias)
end
local function boolean(key, path, title, help) field(key, path, "boolean", title, help) end
for _,key in ipairs({"id","condition","flag","boss_id","continue_policy","return_room","title","body","credits","music","artwork","reward_flag"}) do
    local title = key == "id" and "ID" or (key:gsub("_", " "):gsub("^%l", string.upper):gsub(" id$", " ID"))
    field("ending_"..key,"game_completion."..key,"string", title, "Ending "..key:gsub("_"," ").."; saved to project, rebuild before play.")
end
boolean("ending_enabled","game_completion.enabled", "Enabled","Enable the configured game ending.")
number("ending_return_x","game_completion.return_x", "Return X (world px)",-10000000,10000000,"Return checkpoint X in world pixels.")
number("ending_return_y","game_completion.return_y", "Return Y (world px)",-10000000,10000000,"Return checkpoint Y in world pixels.")
-- Ordered choices are shared by the native and in-game ending editors.
for key, choices in pairs({ ending_condition = { "region", "flag", "boss" },
    ending_continue_policy = { "completed", "explore" } }) do
    local spec = M.fields[key]
    spec.choices, spec.values = choices, {}
    for _, value in ipairs(choices) do spec.values[value] = true end
end
M.fields.ending_flag.applies_when = { "ending_condition=flag" }
M.fields.ending_boss_id.applies_when = { "ending_condition=boss" }
for _, key in ipairs({ "ending_return_room", "ending_return_x", "ending_return_y" }) do
    M.fields[key].applies_when = { "ending_continue_policy=explore" }
end
M.fields.ending_body.multiline, M.fields.ending_credits.multiline = true, true

number("player_scale", "player.player_scale", "Player size (1 = 100%)", PlayerScale.MIN_SCALE, PlayerScale.MAX_SCALE, "Player Size: 1.00 (100%) uses the model's own in-game pixels; changing it stretches the model and requires rebuilding player resources.")
boolean("scale_movement", "player.scale_movement", "Scale movement with size", "Also scale movement with player size; false scales geometry only.")
number("walk_speed", "player.walk_speed", "Walk speed (px/s)", 100, 5000, "Walking speed in base pixels per second.")
number("run_speed", "player.run_speed", "Run speed (px/s)", 200, 5000, "Running speed in base pixels per second.")
number("jump_height", "player.jump_height", "Jump height (px)", 50, 1000, "Jump height in base pixels.")
number("gravity", "player.gravity", "Gravity", -5000, 0, "Downward acceleration; negative base pixels per second squared.")
number("max_health", "player.max_health", "Max health", 1, 100, "Maximum starting health.")
number("max_energy", "player.max_energy", "Max energy", 0, 100, "Maximum starting energy.")
number("max_stamina", "player.max_stamina", "Max stamina", 0, 1000, "Maximum starting stamina.")
number("air_accel_mult", "player.air_accel_mult", "Air control", 0, 2, "Air steering multiplier.")
number("coyote_time", "player.coyote_time", "Coyote time (seconds)", 0, 1, "Seconds after leaving a ledge during which jumping is allowed.")
number("attack_buffer", "player.attack_buffer", "Attack buffer (seconds)", 0, 1, "Seconds to retain a buffered attack input.")
number("air_jumps", "player.air_jumps", "Air jumps", 0, 10, "Extra mid-air jumps once Double Jump is unlocked.")
number("slide_speed", "player.slide.speed", "Slide speed (px/s)", 0, 5000, "Slide speed in base pixels per second.")
number("air_dash_speed", "player.air_dash.speed", "Air dash speed (px/s)", 0, 5000, "Air dash speed in base pixels per second.")
number("air_dash_count", "player.air_dash.max_air_dashes", "Air dash count", 0, 10, "Air dashes available before landing.")
number("wall_climb_speed", "player.wall_climb.climb_speed", "Wall climb speed (px/s)", 0, 5000, "Wall climb speed in base pixels per second.")
number("wall_cling_fall_speed", "player.wall_climb.stick_speed", "Cling fall speed (px/s)", 0, 5000, "Downward speed while clinging; zero stays still.")
local grapple_help_suffix = " Applies whenever Grapple is unlocked — at the start or by pickup."
local function grapple(key, path, kind, default, label, units, help, min, max, applies_when, choices)
    local title_units = units:gsub("^base ", "")
    -- Acceleration units (px/s^2) read badly in a title; the help text keeps them.
    local title = sentence(label) .. ((title_units ~= "" and not title_units:find("^", 1, true))
        and (" (" .. title_units .. ")") or "")
    field(key, "player.grapple." .. path, kind, title, help .. grapple_help_suffix, min, max)
    local spec = M.fields[key]
    spec.default, spec.label, spec.units, spec.page = default, label, units, 7
    spec.applies_when, spec.choices = applies_when, choices
    if choices then
        spec.values = {}
        for _, value in ipairs(choices) do spec.values[value] = true end
    end
end
grapple("grapple_style", "mode", "string", "swing", "Grapple style", "",
    "Swing: hold onto the rope and swing back and forth with Left/Right (an analog stick pushes harder the further you tilt it). Pull: the rope reels you straight to the hook.", nil, nil, nil, {"swing", "pull"})
grapple("grapple_targets", "targets", "string", "surfaces", "Hook catches", "",
    "Where the hook catches. Surfaces: only Grapple Surface rectangles, painted grapple layers and grapple points. Ceilings: also the underside of any solid terrain.", nil, nil, nil, {"surfaces", "ceilings"})
grapple("grapple_stay_hooked", "stay_hooked", "boolean", false, "Stay hooked", "",
    "Off: hold Grapple to stay on the rope; release the button to let go. On: the rope stays after you release the button, so you can keep swinging with the stick; press Grapple again or Jump to let go.")
grapple("grapple_reel", "reel_enabled", "boolean", false, "Extend / retract rope", "",
    "Let Up/Down climb or descend the rope while hooked. Off keeps the rope at the length it had when the hook caught.", nil, nil, {"grapple_style=swing"})
grapple("grapple_break_on_impact", "release_on_impact", "boolean", true, "Break on impact", "",
    "Release the rope on landing or a fast wall or ceiling impact. Gentle wall touches keep the rope.")
grapple("grapple_walls", "allow_walls", "boolean", false, "Catch walls", "",
    "In Ceilings mode, also let the hook catch untagged terrain walls. Floors never catch.", nil, nil, {"grapple_targets=ceilings"})
grapple("grapple_range", "range_px", "number", 800, "Range", "base px",
    "Grapple reach in base pixels; match this to your authored rooms.", 0, 10000)
grapple("grapple_swing_strength", "swing_acceleration", "number", 2000, "Swing Power", "base px/s^2",
    "How strongly Left/Right builds swing speed, in base pixels per second squared.", 0, 10000, {"grapple_style=swing"})
grapple("grapple_swing_speed", "swing_max_speed", "number", 1200, "Swing Top Speed", "base px/s",
    "Maximum speed earned by Left/Right pumping, in base pixels per second. Gravity can carry you faster.", 100, 6000, {"grapple_style=swing"})
grapple("grapple_swing_fade", "swing_drag", "number", 0.12, "Swing Fade", "",
    "How quickly a swing dies down when you stop steering. 0 never fades; the default 0.12 fades slowly; 1 stops a swing within a few seconds.", 0, 5, {"grapple_style=swing"})
grapple("grapple_reel_speed", "reel_speed", "number", 320, "Reel Speed", "base px/s",
    "How quickly Up/Down changes rope length when reeling is on, in base pixels per second.", 0, 3000, {"grapple_style=swing", "grapple_reel"})
grapple("grapple_pull_speed", "pull_speed", "number", 2200, "Pull Speed", "base px/s",
    "Pull style only: how fast the rope pulls you to the hook, in base pixels per second.", 100, 6000, {"grapple_style=pull"})
grapple("grapple_momentum", "release_momentum_mult", "number", 1, "Momentum Kept", "multiplier",
    "How much rope speed you keep when you let go (button, second press or Jump). 1 keeps all of it, 0.5 half, 0 drops straight down; above 1 slingshots. Let-go Boost and Lift are added afterwards.", 0, 2)
grapple("grapple_release_carry", "release_carry_time", "number", 0.35, "Carry Time", "seconds",
    "Seconds that momentum carries you after letting go, losing an anchor or leaving its room. Zero restores normal air braking immediately.", 0, 2)
grapple("grapple_release_float", "release_gravity_mult", "number", 0.6, "Let-go Float", "multiplier",
    "Gravity right after letting go, while momentum carries you. Lower is floatier and gives more time to re-hook. 1 = normal.", 0.2, 1)
grapple("grapple_release_boost", "release_boost_px", "number", 150, "Let-go Boost", "base px/s",
    "Extra speed in your travel direction when you let go, in base pixels per second. Zero preserves your earned speed.", 0, 3000)
grapple("grapple_release_lift", "release_up_boost_px", "number", 0, "Let-go Lift", "base px/s",
    "Extra upward speed when you let go, in base pixels per second. Zero preserves your earned vertical speed.", 0, 3000)
grapple("grapple_rehook_window", "recast_window_s", "number", 0.3, "Re-hook Time", "seconds",
    "Hold Grapple after a miss and it keeps trying for this many seconds.", 0, 1)
number("melee_light_damage", "combat.melee_light.damage", "Light damage", 0, 1000, "Light attack damage.", "light_damage")
number("melee_heavy_damage", "combat.melee_heavy.damage", "Heavy damage", 0, 1000, "Heavy attack damage.", "heavy_damage")
number("ranged_damage", "combat.ranged.damage", "Ranged damage", 0, 1000, "Projectile damage.")
number("ranged_projectile_speed", "combat.ranged.projectile_speed", "Projectile speed (px/s)", 0, 10000, "Projectile speed in base pixels per second.", "ranged_speed")
number("melee_light_cooldown", "combat.melee_light.cooldown", "Light cooldown (seconds)", 0, 10, "Light attack cooldown in seconds.")
number("parry_window", "combat.parry.window", "Parry window (seconds)", 0, 5, "Parry window in seconds.")
for _, attack in ipairs({ "light", "heavy" }) do
    for _, dimension in ipairs({ "width", "height" }) do
        number(attack .. "_hitbox_" .. dimension, "combat.melee_" .. attack .. ".hitbox." .. dimension,
            (attack:gsub("^%l", string.upper)) .. " hitbox " .. dimension .. " (px)", 1, 10000, "Attack hitbox " .. dimension .. " in base pixels.")
    end
end
for _, key in ipairs({ "combo_chaining", "mixed_finishers", "attack_cancels", "parry", "perfect_parry", "parry_counter", "aerial_attacks", "aerial_juggle" }) do
    boolean(key, "combat.features." .. key, ((key:gsub("_", " ")):gsub("^%l", string.upper)), "Enable " .. key:gsub("_", " ") .. ".")
end
-- These children retain their saved values when their parent feature is off;
-- the editor explains the same gates already applied by controls() above.
M.fields.mixed_finishers.applies_when = { "combo_chaining" }
M.fields.perfect_parry.applies_when = { "parry" }
M.fields.parry_counter.applies_when = { "parry" }
M.fields.aerial_juggle.applies_when = { "aerial_attacks" }
boolean("camera_shake", "game_settings.camera_shake", "Camera shake", "Default camera shake; player preferences may override it.")
boolean("damage_numbers", "game_settings.damage_numbers", "Damage numbers", "Default damage number visibility.")
boolean("death_drop_enabled", "progression.death.drop_enabled", "Death drop",
    "On: dying drops part of your currency where you died; collect it to get it back. Dying again before collecting it loses it. Off: you respawn with everything you had at your last save.")
number("death_currency_fraction", "progression.death.currency_loss_fraction", "Currency dropped", 0, 1,
    "After restoring your last save, drop this fraction of the saved currency, rounded down. Minimum Dropped can raise the amount; it never exceeds the currency you hold or a configured maximum.")
number("death_minimum", "progression.death.min_loss", "Minimum dropped (currency)", 0, 100000,
    "Drop at least this much saved currency when Death drop is on. The fraction is rounded down first; the result never exceeds the currency you hold or a configured maximum.")
M.fields.death_drop_enabled.label, M.fields.death_drop_enabled.page = "Death drop", 5
M.fields.death_currency_fraction.label, M.fields.death_currency_fraction.page = "Currency Dropped", 5
M.fields.death_minimum.label, M.fields.death_minimum.page = "Minimum Dropped", 5
M.fields.death_currency_fraction.applies_when = { "death_drop_enabled" }
M.fields.death_minimum.applies_when = { "death_drop_enabled" }
M.fields.death_currency_fraction.step, M.fields.death_minimum.step = 0.05, 10
M.fields.death_minimum.units = "currency"
field("icon_theme", "game_settings.icon_theme", "string", "Icon theme", "Controller prompt artwork: xbox, playstation, or switch.")
M.fields.icon_theme.values = { xbox = true, playstation = true, switch = true }
M.fields.icon_theme.choices = { "xbox", "playstation", "switch" }
for id, ability in pairs(AbilityConfig.abilities or {}) do
    local name = type(ability) == "table" and ability.name or id
    local description = type(ability) == "table" and ability.description or nil
    boolean(id .. "_enabled", "abilities." .. id, sentence(name), (description and (name .. ": " .. description .. ". ") or "")
        .. "Checked starts new games with " .. name .. " unlocked. Unchecked: the player finds it as a pickup. Its settings on the Advanced and Grapple pages apply either way.")
end
-- These labels are the authored Abilities-page labels. Registry names remain
-- the source for every other ability, including future configured abilities.
M.fields.air_dash_iframes_enabled.title = "Dash invincibility"
M.fields.slide_iframes_enabled.title = "Slide invincibility"
for key, name in pairs({ air_jumps = "Double Jump", slide_speed = "Slide", air_dash_speed = "Air Dash",
    air_dash_count = "Air Dash", wall_climb_speed = "Wall Climb", wall_cling_fall_speed = "Wall Climb" }) do
    M.fields[key].help = M.fields[key].help .. " Applies whenever " .. name .. " is unlocked — at the start or by pickup."
end

-- Numeric presentation metadata is shared with editor controls.
for key, step in pairs({
    player_scale = 0.05,
    walk_speed = 25,
    run_speed = 50,
    jump_height = 8,
    gravity = 50,
    max_health = 1,
    max_energy = 1,
    max_stamina = 10,
    air_accel_mult = 0.05,
    coyote_time = 0.02,
    attack_buffer = 0.01,
    air_jumps = 1,
    slide_speed = 100,
    air_dash_speed = 100,
    air_dash_count = 1,
    wall_climb_speed = 50,
    wall_cling_fall_speed = 25,
    melee_light_damage = 1,
    melee_light_cooldown = 0.02,
    melee_heavy_damage = 1,
    ranged_damage = 1,
    ranged_projectile_speed = 100,
    parry_window = 0.02,
    death_currency_fraction = 0.05,
    death_minimum = 10,
    grapple_range = 32,
    grapple_swing_strength = 100,
    grapple_swing_speed = 50,
    grapple_swing_fade = 0.01,
    grapple_reel_speed = 20,
    grapple_pull_speed = 50,
    grapple_momentum = 0.05,
    grapple_release_carry = 0.05,
    grapple_release_float = 0.05,
    grapple_release_boost = 25,
    grapple_release_lift = 25,
    grapple_rehook_window = 0.05,
}) do M.fields[key].step = step end
-- Present counts as integers while preserving older fractional documents.
for _, key in ipairs({"max_health", "max_energy", "max_stamina", "air_jumps", "air_dash_count"}) do
    M.fields[key].editor_integer = true
end

local defaults = {
    player_scale=1, scale_movement=true, walk_speed=1200, run_speed=2000,
    jump_height=256, gravity=-2400, max_health=5, max_energy=3, max_stamina=100,
    air_accel_mult=0.8, coyote_time=0.12, attack_buffer=0.15, air_jumps=1,
    slide_speed=2200, air_dash_speed=1800, air_dash_count=1, wall_climb_speed=600,
    wall_cling_fall_speed=0, melee_light_damage=1,
    melee_heavy_damage=2, ranged_damage=1, ranged_projectile_speed=1200,
    melee_light_cooldown=0.18, parry_window=0.18, camera_shake=true,
    damage_numbers=false, death_drop_enabled=false, death_currency_fraction=0.20, death_minimum=0,
    icon_theme="xbox", light_hitbox_width=120,
    light_hitbox_height=100, heavy_hitbox_width=154, heavy_hitbox_height=116,
}
for key, spec in pairs(M.fields) do
    if spec.default == nil then spec.default = defaults[key] end
    if spec.default == nil and spec.type == "boolean" then
        local ability = AbilityConfig.abilities[key:gsub("_enabled$", "")]
        spec.default = ability and ability.starts_unlocked == true or not ability
    end
    spec.label = spec.label or key:gsub("_enabled$", ""):gsub("_", " ")
    spec.owner = "creator"
    spec.scope = "microvania"
    spec.rebuild = true
    spec.units = spec.units or (spec.type ~= "number" and "" or
        (key:find("speed") and "base px/s" or key == "gravity" and "base px/s^2"
        or (key:find("time") or key:find("window") or key:find("cooldown") or key:find("buffer")) and "seconds"
        or (key:find("height") or key:find("width") or key:find("range")) and "base px" or ""))
end

-- Keep both old base-pixel values and their converted values valid. Widen the
-- bound farthest from zero; numeric steps follow the new units.
local scaled_fields = { ["combat.ranged.projectile_speed"] = true }
for _, paths in pairs(PlayerScale.SCALED_KEYS) do
    for _, path in ipairs(paths) do scaled_fields["player." .. path] = true end
end
for _, attack in ipairs({ "light", "heavy" }) do
    for _, axis in ipairs({ "width", "height" }) do
        scaled_fields["combat.melee_" .. attack .. ".hitbox." .. axis] = true
    end
end
for _, spec in pairs(M.fields) do
    if scaled_fields[spec.path] then
        if spec.default ~= nil then spec.default = spec.default * 1.75 end
        if spec.min and spec.max then
            if math.abs(spec.min) > math.abs(spec.max) then
                spec.min = spec.min * 1.75
            else spec.max = spec.max * 1.75 end
        end
        if spec.step then spec.step = spec.step * 1.75 end
    end
end

-- Toggle groups and ordering feed the editor layout and ability categories.
local function toggle(key, group, order)
    M.fields[key].toggle = { group=group, order=order }
end
toggle("camera_shake", "game", 1)
toggle("damage_numbers", "game", 2)
toggle("death_drop_enabled", "game", 3)
toggle("combo_chaining", "feature", 1)
toggle("mixed_finishers", "feature", 2)
toggle("attack_cancels", "feature", 3)
toggle("parry", "feature", 4)
toggle("perfect_parry", "feature", 5)
toggle("parry_counter", "feature", 6)
toggle("aerial_attacks", "feature", 7)
toggle("aerial_juggle", "feature", 8)
toggle("grapple_stay_hooked", "grapple", 1)
toggle("grapple_reel", "grapple", 2)
toggle("grapple_break_on_impact", "grapple", 3)
toggle("grapple_walls", "grapple", 4)
-- Registry order (movement, combat, defensive, then other categories) keeps
-- keyboard/controller navigation aligned with the grouped Abilities page.
for i, entry in ipairs(require("developer.tools.ability_defaults_writer").ordered_abilities()) do
    toggle(entry.id .. "_enabled", "ability", i)
    M.fields[entry.id .. "_enabled"].toggle.category = entry.category or "other"
end
function M.toggle_fields(group)
    local out = {}
    for key,spec in pairs(M.fields) do
        if spec.toggle and spec.toggle.group == group then
            local field = M.copy(spec.toggle)
            field.key, field.default = key, spec.default
            field.page, field.applies_when = spec.page, M.copy(spec.applies_when)
            field.help, field.units, field.name = spec.help, spec.units, spec.label
            field.id = key:gsub("_enabled$", "")
            out[#out+1] = field
        end
    end
    table.sort(out, function(a,b) return a.order < b.order end)
    return out
end

for _,spec in ipairs(require("developer.tools.designer_fields").fields) do M.fields[spec.key]=spec end

local function validate_value(key, value, spec)
    assert(type(value) == spec.type, key .. " must be a " .. spec.type)
    if spec.type == "number" then
        assert(value == value and value > -math.huge and value < math.huge, key .. " must be finite")
        assert(value >= spec.min and value <= spec.max, key .. " is outside its supported range")
        assert(not spec.integer or value==math.floor(value),key.." must be a whole number")
    elseif spec.values then assert(spec.values[value], key .. " has an unsupported value") end
end

-- Also validates that unknown preserved data can be safely serialized.
local function encode(value, indent, ancestors, comments, path)
    local kind = type(value)
    if kind == "string" then return string.format("%q", value) end
    if kind == "boolean" then return tostring(value) end
    if kind == "number" then
        assert(value == value and value > -math.huge and value < math.huge, "Non-finite settings value")
        return Number.general(value)
    end
    assert(kind == "table", "Settings contain unsupported " .. kind .. " data")
    assert(not ancestors[value], "Settings contain a cycle")
    ancestors[value] = true
    local keys = {}
    for k in pairs(value) do
        assert(type(k) == "string" or (type(k) == "number" and k == math.floor(k)), "Unsupported settings key")
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return type(a) == type(b) and a < b or type(a) < type(b) end)
    local rows = { "{" }
    for _, k in ipairs(keys) do
        local full = path == "" and tostring(k) or path .. "." .. tostring(k)
        if comments and comments[full] then rows[#rows + 1] = indent .. "    -- " .. comments[full] end
        local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
        rows[#rows + 1] = indent .. "    " .. key .. " = " .. encode(value[k], indent .. "    ", ancestors, comments, full) .. ","
    end
    rows[#rows + 1] = indent .. "}"
    ancestors[value] = nil
    return table.concat(rows, "\n")
end

function M.encode(value) return encode(value, "", {}, nil, "") end

function M.validate(doc)
    assert(type(doc) == "table" and doc.version == M.VERSION, "Unsupported creator settings version")
    assert(doc.player_units == nil or doc.player_units == 1 or doc.player_units == 2,
        "player_units must be 1 or 2 (absent means 1)")
    assert(type(doc.overrides) == "table", "Creator settings overrides must be a table")
    assert(doc.published == nil or type(doc.published) == "boolean", "published must be a boolean")
    M.encode(doc)
    for key, spec in pairs(M.fields) do
        local parent = doc.overrides
        local prefix = spec.path:match("^(.*)%.[^.]+$")
        for part in prefix:gmatch("[^.]+") do
            if parent == nil then break end
            assert(type(parent) == "table", "Invalid settings section for " .. spec.path)
            parent = parent[tonumber(part) or part]
        end
        assert(parent == nil or type(parent) == "table", "Invalid settings section for " .. spec.path)
        local value = get(doc.overrides, spec.path)
        if value ~= nil then validate_value(key, value, spec) end
    end
    return doc
end

-- Pixel-unit markers are independent of the unchanged version-1 document schema.
function M.baseline_units(baseline_player)
    local units = baseline_player and baseline_player.units_version or 1
    assert(units == 1 or units == 2, "player_settings.units_version must be 1 or 2")
    return units
end

function M.needs_player_units_migration(doc, baseline_player)
    return (doc.player_units or 1) == 1 and M.baseline_units(baseline_player) == 2
end

function M.migrate(doc, baseline_player)
    M.validate(doc)
    if not M.needs_player_units_migration(doc, baseline_player) then return doc, false end
    local converted = M.copy(doc)
    local old_player = doc.overrides.player or {}
    local old_scale = old_player.player_scale or OldPlayerUnits.player_scale
    local new_scale = old_scale / 1.75
    local movement = old_player.scale_movement
    if movement == nil then movement = OldPlayerUnits.scale_movement end
    if old_player.player_scale ~= nil then put(converted.overrides, "player.player_scale", new_scale) end
    local function solve(path, old_base, new_base, scaled)
        local override = get(doc.overrides, path)
        local old_value = override ~= nil and override or old_base
        if type(old_value) ~= "number" then return end
        local old_effective = old_value * (scaled and old_scale or 1)
        local new_factor = scaled and new_scale or 1
        local new_effective = type(new_base) == "number" and new_base * new_factor or nil
        if new_effective == nil or math.abs(old_effective - new_effective)
            > 1e-6 * math.max(math.abs(old_effective), math.abs(new_effective), 1) then
            put(converted.overrides, path, old_effective / new_factor)
        else remove(converted.overrides, path) end
    end
    for family, paths in pairs(CreatorPixelPaths) do
        for _, path in ipairs(paths) do
            if family == "always" then
                local override = get(doc.overrides, path)
                if type(override) == "number" then
                    put(converted.overrides, path, override * 1.75)
                end
            else
                local player_path = path:match("^player%.(.+)$")
                local old_base, new_base
                if player_path then
                    old_base, new_base = get(OldPlayerUnits, player_path), get(baseline_player, player_path)
                else
                    old_base, new_base = OldPlayerUnits.ranged_projectile_speed,
                        OldPlayerUnits.ranged_projectile_speed * 1.75
                end
                solve(path, old_base, new_base, movement ~= false)
            end
        end
    end
    converted.player_units = 2
    return M.validate(converted), true
end

-- Pure loader: no disk access, and no mutation when units already agree.
function M.load_document(doc, baseline_player)
    M.validate(doc)
    local baseline_units = M.baseline_units(baseline_player)
    if (doc.player_units or 1) == baseline_units then return doc, false end
    assert(not (doc.player_units == 2 and baseline_units == 1),
        "creator_settings.lua was saved for the new player units, but developer/config/player_settings.lua is from an older toolkit. Replace it with the toolkit's player_settings.lua (it has units_version = 2).")
    return M.migrate(doc, baseline_player)
end

function M.from_controls(values, previous, baseline_player)
    values = values or {}
    baseline_player = baseline_player or require "developer.config.player_settings"
    local doc = M.copy(M.load_document(previous or {
        version = M.VERSION, player_units = M.baseline_units(baseline_player), overrides = {},
    }, baseline_player))
    doc.player_units = M.baseline_units(baseline_player)
    doc.published = true
    for key, spec in pairs(M.fields) do
        local value = values[key]
        if value == nil and spec.alias then value = values[spec.alias] end
        if value ~= nil then
            validate_value(key, value, spec)
            put(doc.overrides, spec.path, value)
        end
    end
    if values.wall_climb_speed ~= nil then put(doc.overrides, "player.wall_climb.speed", values.wall_climb_speed) end
    -- Starting availability is separate from the count used after acquisition.
    -- The player already gates extra jumps through AbilityManager.
    return M.validate(M.prune_legacy(doc))
end

function M.serialize(doc, baseline_player)
    baseline_player = baseline_player or require "developer.config.player_settings"
    doc = M.copy(M.load_document(doc, baseline_player))
    doc.player_units = M.baseline_units(baseline_player)
    local comments = {
        player_units = "Pixel-unit generation for player, combat and imported-art overrides (unitless): 1 = old base pixels, 2 = in-game-size base pixels; safe values 1 or 2.",
    }
    for _, spec in pairs(M.fields) do comments["overrides." .. spec.path] = spec.help end
    return "-- Project-owned settings. Saved by Project > Game Settings...\n"
        .. "-- Overrides are merged over the commented baseline configuration files.\n"
        .. "-- Remove a field to inherit its baseline value; preserve version.\n"
        .. "-- published=true enables these overrides; legacy local values require explicit import.\n"
        .. "return " .. encode(doc, "", {}, comments, "") .. "\n"
end

return M
