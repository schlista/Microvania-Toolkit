components {
  id: "save_point"
  component: "/mvtk/prefabs/save_point.script"
  properties {
    id: "display_name"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "heal_on_save"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "restore_energy"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "is_fast_travel"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "show_on_map"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "requires_interact"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "save_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "room_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
}
embedded_components {
  id: "collisionobject"
  type: "collisionobject"
  data: "type: COLLISION_OBJECT_TYPE_TRIGGER\n"
  "mass: 0.0\n"
  "friction: 0.1\n"
  "restitution: 0.5\n"
  "group: \"sensor\"\n"
  "mask: \"player\"\n"
  "embedded_collision_shape {\n"
  "  shapes {\n"
  "    shape_type: TYPE_BOX\n"
  "    position {\n"
  "      x: 0.0\n"
  "      y: 32.0\n"
  "      z: 0.0\n"
  "    }\n"
  "    rotation {\n"
  "      x: 0.0\n"
  "      y: 0.0\n"
  "      z: 0.0\n"
  "      w: 1.0\n"
  "    }\n"
  "    index: 0\n"
  "    count: 3\n"
  "  }\n"
  "  data: 32.0\n"
  "  data: 32.0\n"
  "  data: 5.0\n"
  "}\n"
  ""
}
