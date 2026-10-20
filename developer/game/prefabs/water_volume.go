components {
  id: "script"
  component: "/mvtk/prefabs/water_volume.script"
  properties {
    id: "water_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "water_type"
    value: "water"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "width"
    value: "128.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "height"
    value: "128.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "swim_enabled"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "swim_speed_mult"
    value: "0.7"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "damage"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "damage_interval"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "current_direction"
    value: "none"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "current_strength"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "room_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "buoyancy"
    value: "0.5"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "water_drag"
    value: "0.85"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "oxygen_drain"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "oxygen_drain_rate"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "surface_y_offset"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "splash_effect"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "tint_color"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "show_sprite"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
}
embedded_components {
  id: "sprite"
  type: "sprite"
  data: "default_animation: \"prop_base\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/developer/assets/atlas/gameplay_visuals.atlas\"\n"
  "}\n"
  ""
}
embedded_components {
  id: "distortion"
  type: "sprite"
  data: "default_animation: \"water_distortion_mask\"\n"
  "material: \"/developer/materials/distortion_zone.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/developer/assets/atlas/gameplay_visuals.atlas\"\n"
  "}\n"
  ""
}
embedded_components {
  id: "collisionobject"
  type: "collisionobject"
  data: "type: COLLISION_OBJECT_TYPE_TRIGGER\n"
  "mass: 0.0\n"
  "friction: 0.0\n"
  "restitution: 0.0\n"
  "group: \"water\"\n"
  "mask: \"player\"\n"
  "mask: \"enemy\"\n"
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
  "  data: 5.0\n"
  "}\n"
  ""
}
