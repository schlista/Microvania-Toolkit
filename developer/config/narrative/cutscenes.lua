-- developer/config/narrative/cutscenes.lua
-- Base/manual cutscene table.
-- Tiled-generated cutscenes are written to:
--   developer/config/narrative/cutscenes_generated.lua
-- Runtime merges both tables (generated entries can override matching IDs).
-- Flow: Tiled cutscene_id (for example a boss's intro_cutscene) -> an entry
--   here -> video_id -> developer/config/narrative/videos.lua uri
-- Steps:
--  { type = "fade", to = "in"|"out" }
--  { type = "wait", t = seconds }
--  { type = "dialogue", id = "dialogue_id" }
--  { type = "video", video_id = "clip_id" } -- clip lives in developer/config/narrative/videos.lua
--  { type = "message", url = <msg.url() table or string path>, id = hash("msg"), data = {} }

return {
  -- Add your cutscenes here, keyed by the cutscene_id used in Tiled.
}
