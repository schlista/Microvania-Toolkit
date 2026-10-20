-- developer/config/attack_patterns.lua
-- Optional boss attack-pattern overrides.
--
-- Leave this table empty to use the built-in boss patterns in
-- mvtk/bosses/patterns/attack_patterns.lua. Named entries merge over those
-- patterns at startup; they must follow mvtk/bosses/attack_pattern_schema.lua.
-- Select an attack pattern on each boss phase object in Tiled.
-- These patterns use your own world pixels and are not scaled with tile size.
-- Optional scale_with_tiles = true opts a pattern into the framework's tile
-- factor (unitless boolean, safe false/true; false is the default).
return {}

