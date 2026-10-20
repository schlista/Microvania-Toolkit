components {
  id: "hazard_zone"
  component: "/mvtk/world/hazard_zone.script"
  properties {
    id: "hazard_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "hazard_type"
    value: "spikes"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "damage"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "damage_interval"
    value: "0.5"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "knockback_force"
    value: "300.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "required_resistance"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "instant_kill"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "enabled"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "sound_on_hit"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "retractable"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "retract_time"
    value: "2.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "extend_time"
    value: "2.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "start_retracted"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "arena_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "active_phases"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "pattern"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "pattern_speed"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "room_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
}
embedded_components {
  id: "collision"
  type: "collisionobject"
  data: "collision_shape: \"\"\n"
  "type: COLLISION_OBJECT_TYPE_TRIGGER\n"
  "mass: 0.0\n"
  "friction: 0.1\n"
  "restitution: 0.5\n"
  "group: \"hazard\"\n"
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
  "  data: 32.0\n"
  "  data: 10.0\n"
  "}\n"
  ""
}
