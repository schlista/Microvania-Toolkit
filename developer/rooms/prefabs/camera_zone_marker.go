components {
  id: "script"
  component: "/developer/rooms/prefabs/camera_zone_marker.script"
}
embedded_components {
  id: "sprite"
  type: "sprite"
  data: "tile_set: \"/developer/assets/atlas/gameplay_visuals.atlas\"\n"
  "default_animation: \"prop_base\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "blend_mode: BLEND_MODE_ALPHA\n"
  ""
  scale {
    x: 1.0
    y: 1.0
    z: 1.0
  }
}

