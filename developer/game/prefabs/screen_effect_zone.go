components {
  id: "script"
  component: "/mvtk/prefabs/screen_effect_zone.script"
  properties {
    id: "zone_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "effect_type"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "intensity"
    value: "0.5"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "tint_color"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "duration"
    value: "0.3"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "trigger_once"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "exit_darkness"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "exit_tint"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "underwater_overlay"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
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
