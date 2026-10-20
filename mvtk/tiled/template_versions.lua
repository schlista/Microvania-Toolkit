-- mvtk/tiled/template_versions.lua
--
-- Single source of truth for the supported MV Toolkit template format.
--
-- Every Tiled object template under tiled/templates/**/*.tx carries an
-- `mvtk_template_version` custom property. The validator
-- (tools/validate_tiled_export.lua) and the editor build hook compare each
-- template / export against the values below to surface incompatibilities
-- before bundling.
--
-- Bump CURRENT whenever a template's required properties change in a
-- backward-incompatible way (renamed property, new required field, removed
-- handler). Add the previous value to SUPPORTED so projects pinned to the
-- old format still work; remove it from SUPPORTED in the next major release.

local M = {}

-- Latest template schema version shipped in this branch.
M.CURRENT = "2.8.0"

-- Versions the runtime accepts during validation. Keep ordered newest-first.
M.SUPPORTED = {
    "2.8.0",
    "2.7.0",
    "2.6.0",
    "2.5.0",
    "2.4.0",
    "2.3.0",
    "2.2.0",
    "2.1.0",
}

-- Convenience lookup: M.is_supported("2.3.0") -> true.
function M.is_supported(version)
    if version == nil then return false end
    local v = tostring(version)
    for _, supported in ipairs(M.SUPPORTED) do
        if supported == v then return true end
    end
    return false
end

return M
