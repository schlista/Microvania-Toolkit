components {
  id: "script"
  component: "/mvtk/prefabs/arena_lock_marker.script"
  properties {
    id: "boss_type"
    value: "default_boss"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "lock_on_enter"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "unlock_on_clear"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "zone_width"
    value: "512.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "zone_height"
    value: "384.0"
    type: PROPERTY_TYPE_NUMBER
  }
}
embedded_components {
  id: "sprite"
  type: "sprite"
  data: "tile_set: \"/developer/assets/atlas/gameplay_visuals.atlas\"\n"
  "default_animation: \"prop_base\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "blend_mode: BLEND_MODE_ALPHA\n"
  ""
}
embedded_components {
  id: "co"
  type: "collisionobject"
  data: "type: COLLISION_OBJECT_TYPE_TRIGGER\n"
  "mass: 0.0\n"
  "friction: 0.0\n"
  "restitution: 0.0\n"
  "group: \"world\"\n"
  "embedded_collision_shape {\n"
  "  shapes {\n"
  "    shape_type: TYPE_BOX\n"
  "    position {\n"
  "    }\n"
  "    rotation {\n"
  "    }\n"
  "    index: 0\n"
  "    count: 3\n"
  "  }\n"
  "  data: 64.0\n"
  "  data: 64.0\n"
  "  data: 10.0\n"
  "}\n"
  ""
}
