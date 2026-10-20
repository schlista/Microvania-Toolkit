components {
  id: "script"
  component: "/mvtk/prefabs/secret.script"
  properties {
    id: "secret_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "secret_type"
    value: "illusory_wall"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "reveals_on"
    value: "touch"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "required_ability"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "width"
    value: "64.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "height"
    value: "64.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "hide_tiles"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "notification"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "notification_text"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "reward_type"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "reward_amount"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "map_reveal"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "room_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
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
  id: "collisionobject"
  type: "collisionobject"
  data: "type: COLLISION_OBJECT_TYPE_TRIGGER\n"
  "mass: 0.0\n"
  "friction: 0.0\n"
  "restitution: 0.0\n"
  "group: \"sensor\"\n"
  "mask: \"player\"\n"
  "mask: \"attack\"\n"
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
  "  data: 5.0\n"
  "}\n"
  ""
}
embedded_components {
  id: "attack_trigger"
  type: "collisionobject"
  data: "type: COLLISION_OBJECT_TYPE_TRIGGER\n"
  "mass: 0.0\n"
  "friction: 0.0\n"
  "restitution: 0.0\n"
  "group: \"breakable\"\n"
  "mask: \"attack\"\n"
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
  "  data: 5.0\n"
  "}\n"
  ""
}
