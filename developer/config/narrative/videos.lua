-- developer/config/narrative/videos.lua
-- Video clip catalog used by cutscene steps with type = "video".
-- Naming flow:
--   Tiled trigger property cutscene_id -> cutscenes.lua entry -> video_id below -> MP4 uri/editor_uri
--
-- uri:
--   Path used in bundled builds.
-- editor_uri:
--   Optional path used when running from the Defold editor (project-relative).
-- play_sound:
--   true plays the clip's audio; false keeps it muted (muted clips autoplay
--   more reliably).
-- timeout:
--   Failsafe in seconds: the cutscene continues if the platform video fails,
--   so input is never locked.

return {
    -- Add your clips here, for example:
    -- my_clip = { editor_uri = "developer/assets/cutscenes/my_clip.mp4", uri = "my_clip.mp4", play_sound = true, timeout = 30.0 },
}
