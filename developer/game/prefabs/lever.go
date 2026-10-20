components {
  id: "script"
  component: "/mvtk/prefabs/lever.script"
  properties {
    id: "lever_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "target_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "starts_on"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "toggle"
    value: "true"
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
    id: "label_on"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "label_off"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "range"
    value: "96.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "cooldown"
    value: "0.2"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "set_flag_on"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "set_flag_off"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "requires_flag"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "sound_on"
    value: "lever_on"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "sound_off"
    value: "lever_off"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "on_animation"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "off_animation"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "reset_delay"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
}
embedded_components {
  id: "sprite"
  type: "sprite"
  data: "tile_set: \"/developer/assets/atlas/gameplay_visuals.atlas\"\n"
  "default_animation: \"lever_idle\"\n"
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
  "group: \"interactable\"\n"
  "mask: \"player\"\n"
  "embedded_collision_shape {\n"
  "  shapes {\n"
  "    shape_type: TYPE_BOX\n"
  "    position { x: 0.0 y: 0.0 z: 0.0 }\n"
  "    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\n"
  "    index: 0\n"
  "    count: 3\n"
  "  }\n"
  "  data: 64.0\n"
  "  data: 64.0\n"
  "  data: 10.0\n"
  "}\n"
  ""
}
