components {
  id: "script"
  component: "/mvtk/prefabs/music_trigger.script"
  properties {
    id: "trigger_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "music_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "area_theme"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "fade_time"
    value: "0.5"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "stop_on_exit"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "exit_music"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "exit_area"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "trigger_once"
    value: "false"
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
