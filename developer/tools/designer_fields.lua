-- Designer-page metadata. Paths refer to real runtime configuration consumers.
-- Every field is saved through the shared wizard document; previews never save.
local M={fields={},pages={"Camera","HUD and prompts","Map","Saves and checkpoints","Player art","Movement test"}}
local function add(page,key,title,path,kind,default,help,min,max,choices,step)
    local values; if choices then values={}; for _,v in ipairs(choices) do values[v]=true end end
    M.fields[#M.fields+1]={key=key,title=title,page=page,path=path,type=kind,default=default,help=help,
        min=min,max=max,values=values,choices=choices,step=step or 1,label=key:gsub("_"," "),
        owner="creator",scope="microvania",rebuild=true,units="",action="Save Project, stop, Prepare & Check, Build"}
end
add(1,"camera_zoom","Zoom","camera.default_zoom","number",1,"Global zoom; Tiled camera zones and boss arenas retain authority.",0.1,4,nil,0.1)
add(1,"camera_follow_x","Follow speed X","camera.speed.x","number",99,"Horizontal follow response; higher catches up faster.",1,99)
add(1,"camera_follow_y","Follow speed Y","camera.speed.y","number",99,"Vertical follow response.",1,99)
add(1,"camera_deadzone_x","Dead zone X (world px)","camera.deadzone.x","number",0,"Horizontal dead zone in world pixels.",0,2048,nil,8)
add(1,"camera_deadzone_y","Dead zone Y (world px)","camera.deadzone.y","number",0,"Vertical dead zone in world pixels.",0,2048,nil,8)
add(1,"camera_lookahead","Look-ahead (world px)","camera.lookahead.x","number",0,"Horizontal look-ahead in world pixels.",0,2048,nil,8)
add(1,"camera_offset_x","Offset X (world px)","camera.offset.x","number",0,"Horizontal framing offset in world pixels.",-2048,2048,nil,8)
add(1,"camera_offset_y","Offset Y (world px)","camera.offset.y","number",0,"Vertical framing offset in world pixels.",-2048,2048,nil,8)
add(1,"camera_pixel_snap","Pixel snap","camera.pixel_snap","boolean",true,"Snap rendering to screen pixels; simulation remains fractional.")
add(1,"camera_respawn_snap","Snap on respawn","camera.snap_on_respawn","boolean",true,"Snap on respawn; false uses the configured smooth transition.")
add(1,"camera_respawn_time","Respawn blend time (seconds)","camera.respawn_lerp_time","number",0.2,"Smooth respawn transition in seconds.",0.01,5,nil,0.05)
add(1,"camera_vertical_look","Look up and down","camera.look_y_enabled","boolean",true,"Allow holding up/down to look vertically.")
add(2,"hud_preset","Layout preset","hud_layout.active_preset","string","default","Existing layout preset; individual overrides apply after the preset.",nil,nil,{"default","minimal","bottom_left","centered"})
add(2,"hud_scale","Scale","hud_layout.global.scale","number",1,"Scale HUD elements while retaining their screen anchors.",0.5,2,nil,0.1)
add(2,"hud_theme","Theme","hud_layout.theme_preset","string","authored","Existing theme palette for HUD and prompts; individual color overrides win.",nil,nil,{"authored","classic","neon","minimal","retro","horror"})
for _,name in ipairs({"health_bar","energy_bar","stamina_bar","currency","abilities","interact_hint"}) do
    add(2,"hud_"..name,({health_bar="Health bar",energy_bar="Energy bar",stamina_bar="Stamina bar",currency="Currency",abilities="Abilities",interact_hint="Interact prompt"})[name],"hud_layout."..name..".visible","boolean",true,"Show "..name:gsub("_"," ").." when its gameplay resource is available.")
end
add(2,"hud_health_anchor","Health bar position","hud_layout.health_bar.anchor","string","top_left","Health bar screen anchor.",nil,nil,{"top_left","top_right","bottom_left","bottom_right","top_center","bottom_center"})
for i,name in ipairs({"red","green","blue"}) do
    add(2,"hud_health_"..name,({"Red","Green","Blue"})[i].." (0 to 1)","ui_theme.colors.health."..i,"number",({0.85,0.2,0.15})[i],"Health bar "..name.." channel (0 to 1).",0,1,nil,0.05)
end
add(3,"map_fog","Fog of war","map_discovery.enabled","boolean",true,"Hide unexplored map areas; disabling fog still records discovery.")
add(3,"map_discovery_mode","Discovery mode","map_discovery.mode","string","nearby","Reveal the visible screen plus nearby radius, or reveal the whole current room.",nil,nil,{"nearby","room"})
add(3,"map_reveal_radius","Reveal radius (world px)","map_discovery.reveal_radius","number",512,"Extra reveal radius around the player, beyond the visible screen; preserves saved exploration.",0,8192,nil,32)
add(3,"map_softness","Fog edge softness (world px)","map_discovery.edge_softness","number",128,"Visual fog edge softness in world pixels; does not change discovery.",0,2048,nil,16)
add(3,"map_visible","World map","world_map.enabled","boolean",true,"Allow opening the full world map.")
add(3,"minimap_visible","Minimap","minimap.enabled","boolean",true,"Show the minimap panel.")
add(3,"map_marker_limit","Marker limit","screenshot_markers.max_markers","number",10,"Maximum player-created screenshot map markers.",0,100)
add(3,"map_marker_size","Marker size (GUI px)","minimap.custom_markers.size_px","number",6,"Player-created marker size in GUI pixels.",2,32)
add(4,"save_slots","Save slots","progression.saves.max_slots","number",3,"Visible save slots (1 to 3). Hiding a slot does not erase its file.",1,3)
add(4,"save_autosave","Timed autosave","progression.saves.autosave_enabled","boolean",true,"Enable timed autosaves; explicit checkpoints and progression commits remain durable.")
add(4,"save_interval","Autosave interval (seconds)","progression.saves.autosave_interval","number",0,"Timed autosave seconds; zero uses event saves only.",0,3600,nil,30)
add(4,"save_room_change","Save on room change","progression.saves.autosave_on_room_change","boolean",true,"Request a save when entering another room.")
add(4,"save_pickup","Save on pickup","progression.saves.autosave_on_collectible_pickup","boolean",false,"Save after each collectible pickup.")
add(5,"art_source","Source","player_art.source","string","","PNG sheet or sequence directory. Sequence names: idle_001.png, run_001.png, etc.")
add(5,"art_mode","Mode","player_art.mode","string","sequence","Import uniformly sized PNG frames or slice a regular PNG sheet.",nil,nil,{"sequence","sheet"})
add(5,"art_frame_width","Frame width (source px)","player_art.frame_width","number",64,"Frame width in source pixels; sheets must divide exactly.",1,2048)
add(5,"art_frame_height","Frame height (source px)","player_art.frame_height","number",64,"Frame height in source pixels; sheets must divide exactly.",1,2048)
add(5,"art_animations","Animations","player_art.animations","string","idle=1-1;run=2-5;jump=6-6;fall=7-7","Sheet frame ranges (row-major, starting at 1): name=first-last;name=first-last.")
add(5,"art_mappings","Mappings","player_art.mappings","string","","Optional gameplay=animation mappings separated by semicolons. Required states must resolve.")
add(5,"art_fps","FPS (frames/s)","player_art.fps","number",12,"Animation frames per second.",1,60)
add(5,"art_once","Non-looping animations","player_art.once","string","jump;land;hurt;death","Semicolon-separated non-looping animations; other animations loop.")
add(5,"art_required","Required states","player_art.required","string","idle;run;jump;fall","Semicolon-separated gameplay states to validate. Include custom attack animation names.")
add(5,"art_fallback","Fallback animation","player_art.fallback","string","","Blank rejects missing states. An imported animation name explicitly supplies missing required states.")
add(5,"art_width","Width (world px)","player_art.width","number",0,"Displayed width in world pixels at Player Size 1.00. Zero uses the frame width; a different width stretches the model.",0,7168)
add(5,"art_height","Height (world px)","player_art.height","number",0,"Displayed height in world pixels at Player Size 1.00. Zero uses the frame height; a different height stretches the model.",0,7168)
add(5,"art_origin_x","Origin X (world px)","player_art.offset_x","number",0,"Sprite center offset from the player origin in world pixels at Player Size 1.00.",-3584,3584)
add(5,"art_origin_y","Origin Y (world px)","player_art.offset_y","number",0,"Sprite center offset from the player origin in world pixels at Player Size 1.00.",-3584,3584)
add(5,"art_body_width","Body half-width (world px)","player.collider_half_width","number",46.45158,"Player collider half-width in world pixels at Player Size 1.00.",1,896)
add(5,"art_body_height","Body half-height (world px)","player.collider_half_height","number",59.9999575,"Player collider half-height in world pixels at Player Size 1.00.",1,896)
-- Movement test geometry is authored data, scaled using current player settings.
add(6,"test_floor_tiles","Floor length (tiles)","movement_test.floor_tiles","number",32,"Length of the disposable movement course in tiles.",16,128)
add(6,"test_step_tiles","Step height (tiles)","movement_test.step_tiles","number",2,"Height of the jump obstacle in tiles.",1,8)
add(6,"test_gap_tiles","Gap width (tiles)","movement_test.gap_tiles","number",3,"Width of the dash gap in tiles.",1,12)
for _,f in ipairs(M.fields) do
    if f.key:match("^test_") or f.key:match("^art_frame_") or f.key=="art_fps" or f.key=="save_slots" or f.key=="map_marker_limit" then f.integer=true end
end
return M
