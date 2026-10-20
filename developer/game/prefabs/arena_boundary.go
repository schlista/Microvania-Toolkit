components {
  id: "script"
  component: "/mvtk/prefabs/arena_boundary.script"
  properties {
    id: "enabled_when_locked"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "start_enabled"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "poll_interval"
    value: "0.25"
    type: PROPERTY_TYPE_NUMBER
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
  "  data: 32.0\n"
  "  data: 10.0\n"
  "}\n"
  ""
}
