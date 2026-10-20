components {
  id: "script"
  component: "/mvtk/prefabs/boss_phase_trigger.script"
  properties {
    id: "phase"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "transition_time"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "trigger_once"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "delay"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
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
