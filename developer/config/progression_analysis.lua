-- Authoring-only progression settings; never modifies gameplay or saves.
-- See docs/PROGRESSION_ANALYSIS.md for Tiled annotations and configuration.
return {
    -- Bounds for each search; exhausted bounds produce INCOMPLETE.
    max_states=12000, max_seconds=0.25,
    -- Empty start uses the first placed room. Presets overlay new-game abilities.
    start="", default_preset="new_game",
    presets={new_game={abilities={},items={},flags={}}},
    -- Optional logical-area/door annotations and required/optional objectives.
    rooms={}, objectives={},
    -- GUI font, list size and text-supplementing status colors.
    ui={font="room_label",scale=0.65,rows=10,
        reachable={0.3,1,0.5,1},blocked={1,0.4,0.35,1},unknown={1,0.8,0.25,1}},
}
