components {
  id: "script"
  component: "/mvtk/prefabs/hint_stone.script"
  properties {
    id: "hint_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "label"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "range"
    value: "96.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "title"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "body"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "position"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "duration"
    value: "4.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "set_flag"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "requires_flag"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "sound_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
}
embedded_components {
  id: "sprite"
  type: "sprite"
  data: "default_animation: \"hint_stone_idle\"\n"
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
  "group: \"interactable\"\n"
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
