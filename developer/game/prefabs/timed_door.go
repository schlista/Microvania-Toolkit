components {
  id: "script"
  component: "/mvtk/prefabs/timed_door.script"
  properties {
    id: "door_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "open_duration"
    value: "2.5"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "starts_open"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "auto_close"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "close_on_release"
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
    id: "sound_open"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "sound_close"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "hide_when_open"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "room_id"
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
  data: "default_animation: \"wall_base\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/developer/assets/atlas/gameplay_visuals.atlas\"\n"
  "}\n"
  ""
  scale {
    x: 0.5
  }
}
embedded_components {
  id: "co"
  type: "collisionobject"
  data: "type: COLLISION_OBJECT_TYPE_STATIC\n"
  "mass: 0.0\n"
  "friction: 0.1\n"
  "restitution: 0.0\n"
  "group: \"world\"\n"
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
  "  data: 32.0\n"
  "  data: 64.0\n"
  "  data: 10.0\n"
  "}\n"
  ""
}
