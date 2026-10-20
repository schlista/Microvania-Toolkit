-- mvtk/dialogue/dialogue_registry.lua
-- Merges static dialogue config with runtime-authored dialogue sequences.

local M = {}

local static_sequences = nil
local runtime_sequences = {}
local runtime_meta = {}

local function trim(value)
    local s = tostring(value or "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then
        return nil
    end
    return s
end

local function load_static_sequences()
    if static_sequences ~= nil then
        return static_sequences
    end

    local ok, mod = pcall(require, "developer.config.narrative.dialogues")
    if ok and type(mod) == "table" then
        static_sequences = mod
    else
        static_sequences = {}
    end

    return static_sequences
end

function M.get(dialogue_id)
    local key = trim(dialogue_id)
    if not key then
        return nil
    end

    return runtime_sequences[key] or load_static_sequences()[key]
end

function M.build_sequence_from_text(text, speaker)
    local body = trim(text)
    if not body then
        return {}
    end

    local speaker_name = trim(speaker) or "NPC"
    local sequence = {}
    local normalized = body:gsub("\r\n", "\n"):gsub("\r", "\n")

    for line in (normalized .. "\n"):gmatch("(.-)\n") do
        local text_line = trim(line)
        if text_line then
            sequence[#sequence + 1] = {
                speaker = speaker_name,
                text = text_line,
            }
        end
    end

    return sequence
end

function M.register(dialogue_id, sequence, meta)
    local key = trim(dialogue_id)
    if not key or type(sequence) ~= "table" or #sequence == 0 then
        return nil
    end

    -- Sequence schema validation: every line must be a table with at least
    -- a `text` field (or a `choices` array for branching dialogue). A
    -- malformed sequence at this layer would otherwise wedge the GUI when
    -- played back; surface the error during registration instead.
    for index, line in ipairs(sequence) do
        if type(line) ~= "table" then
            print(string.format("[DIALOGUE_REGISTRY] register('%s'): line %d is not a table; rejecting",
                tostring(key), index))
            return nil
        end
        if line.text == nil and line.choices == nil then
            print(string.format("[DIALOGUE_REGISTRY] register('%s'): line %d missing text/choices; rejecting",
                tostring(key), index))
            return nil
        end
    end

    runtime_sequences[key] = sequence
    runtime_meta[key] = meta or {}
    return key
end

function M.register_text(dialogue_id, text, speaker, meta)
    local sequence = M.build_sequence_from_text(text, speaker)
    if #sequence == 0 then
        return nil
    end

    return M.register(dialogue_id, sequence, meta)
end

function M.clear_room(room_id)
    local key = trim(room_id)
    if not key then
        return
    end

    for dialogue_id, meta in pairs(runtime_meta) do
        if type(meta) == "table" and meta.room_id == key then
            runtime_sequences[dialogue_id] = nil
            runtime_meta[dialogue_id] = nil
        end
    end
end

function M.clear_all_runtime()
    runtime_sequences = {}
    runtime_meta = {}
end

return M
