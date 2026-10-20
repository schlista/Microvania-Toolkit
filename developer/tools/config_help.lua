-- developer/tools/config_help.lua
-- Prints concise help for common config files using developer/config/config_schema.lua
-- Usage: lua developer/tools/config_help.lua

local schema = require "developer.config.config_schema"

print("Config Help (source: developer/config/config_schema.lua)\n")
for file, info in pairs(schema) do
    print(("- %s"):format(file))
    if info.desc then
        print(("  • %s"):format(info.desc))
    end
    if info.fields then
        print(("  • Fields: %s"):format(table.concat(info.fields, ", ")))
    end
    print("")
end

print("Tip: Extend developer/config/config_schema.lua to add more files/fields so tools can surface better help text.")
