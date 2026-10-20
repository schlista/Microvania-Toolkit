components {
  id: "script"
  component: "/mvtk/prefabs/light_source.script"
  properties {
    id: "light_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "radius"
    value: "200.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "intensity"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "enabled"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "track_position"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "room_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
}
embedded_components {
  id: "sprite"
  type: "sprite"
  data: "tile_set: \"/developer/assets/atlas/gameplay_visuals.atlas\"\n"
  "default_animation: \"prop_base\"\n"
  "material: \"/developer/materials/glow_sprite.material\"\n"
  "blend_mode: BLEND_MODE_ALPHA\n"
  ""
  scale {
    x: 0.25
    y: 0.25
    z: 1.0
  }
}
