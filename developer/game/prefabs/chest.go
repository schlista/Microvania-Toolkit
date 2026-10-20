components {
  id: "chest"
  component: "/mvtk/world/chest.script"
  properties {
    id: "chest_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "chest_type"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "loot_table"
    value: "common"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "locked"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "key_required"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "room_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "single_use"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
}
embedded_components {
  id: "sprite"
  type: "sprite"
  data: "tile_set: \"/developer/assets/atlas/gameplay_visuals.atlas\"\n"
  "default_animation: \"chest_base\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "blend_mode: BLEND_MODE_ALPHA\n"
  ""
  scale {
    x: 0.25
    y: 0.25
    z: 1.0
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
  "  data: 16.0\n"
  "  data: 16.0\n"
  "  data: 10.0\n"
  "}\n"
  ""
}
