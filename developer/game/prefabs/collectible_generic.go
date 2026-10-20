components {
  id: "collectible"
  component: "/mvtk/collectibles/collectible.script"
  properties {
    id: "collectible_type"
    value: "health_container"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "collectible_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "amount"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "respawns"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "respawns_override"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "item_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "key_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "lore_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "lore_text"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "relic_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "relic_name"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "relic_description"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "area_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "area_name"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "reveal_radius"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "ability_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "sprite_atlas"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "animation"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "show_popup"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "show_popup_override"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "popup_title"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "popup_description"
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
  "group: \"collectible\"\n"
  "mask: \"player\"\n"
  "embedded_collision_shape {\n"
  "  shapes {\n"
  "    shape_type: TYPE_SPHERE\n"
  "    position { x: 0.0 y: 0.0 z: 0.0 }\n"
  "    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\n"
  "    index: 0\n"
  "    count: 1\n"
  "  }\n"
  "  data: 32.0\n"
  "}\n"
  "locked_rotation: true\n"
  ""
}
