components {
  id: "script"
  component: "/mvtk/prefabs/pressure_plate.script"
  properties {
    id: "plate_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "target_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "required_count"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "allow_player"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "allow_world"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "allow_enemy"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "stays_pressed"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "message_on"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "message_off"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "set_flag"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "sound_on"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "sound_off"
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
  id: "co"
  type: "collisionobject"
  data: "type: COLLISION_OBJECT_TYPE_TRIGGER\n"
  "mass: 0.0\n"
  "friction: 0.0\n"
  "restitution: 0.0\n"
  "group: \"sensor\"\n"
  "mask: \"player\"\n"
  "mask: \"world\"\n"
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
  "  data: 16.0\n"
  "  data: 10.0\n"
  "}\n"
  ""
}
