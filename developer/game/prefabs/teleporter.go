components {
  id: "script"
  component: "/mvtk/prefabs/teleporter.script"
  properties {
    id: "teleporter_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "pair_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "target_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "room_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "requires_flag"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "hide_when_locked"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "active_effect_id"
    value: "collectible_sparkle"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "unlock_effect_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "require_interact"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "cooldown"
    value: "0.5"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "transition_time"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "preserve_velocity"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "facing"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "label"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
}
embedded_components {
  id: "sprite"
  type: "sprite"
  data: "tile_set: \"/developer/assets/atlas/gameplay_visuals.atlas\"\n"
  "default_animation: \"prop_base\"\n"
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
