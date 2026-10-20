-- Project > Game Settings... > Player art. Source art remains creator-owned.
return {
    units_version=2, -- Pixel units for displayed sizes and offsets; unitless version, safe 1 or 2.
    source="", -- PNG sheet or folder of name_001.png animation sequences.
    mode="sequence", -- sequence or sheet.
    frame_width=64, -- Every frame width in source pixels.
    frame_height=64, -- Every frame height in source pixels.
    animations="idle=1-1;run=2-5;jump=6-6;fall=7-7", -- Sheet ranges, row-major, 1-based.
    mappings="", -- Semicolon-separated gameplay=animation overrides.
    required="idle;run;jump;fall;land;double_jump;dash;air_dash;slide;wall_slide;wall_cling;climb;swim;hurt;death;punch;weapon_attack;shoot;running_shooting;air_spin", -- Gameplay states checked before import. Add names used by custom attacks.
    fallback="", -- Blank rejects missing states. Set an imported animation name to explicitly reuse it for missing required states.
    fps=12, -- Playback frames per second.
    once="jump;land;double_jump;dash;air_dash;slide;hurt;death;punch;weapon_attack;shoot;running_shooting;air_spin", -- Non-looping gameplay animations; other names loop.
    width=0, -- Displayed width in world pixels at Player Size 1.00; safe 0..7168, 0 uses the frame width.
    height=0, -- Displayed height in world pixels at Player Size 1.00; safe 0..7168, 0 uses the frame height.
    offset_x=0, -- Sprite center relative to player origin, before scaling.
    offset_y=0, -- Sprite center relative to player origin, before scaling.
}
