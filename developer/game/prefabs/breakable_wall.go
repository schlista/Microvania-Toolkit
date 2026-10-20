components {
  id: "breakable_wall"
  component: "/mvtk/world/breakable_wall.script"
  properties {
    id: "wall_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "wall_type"
    value: "cracked"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "required_ability"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "health"
    value: "3.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "room_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "reveals_secret"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "drop_collectible"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "swap_tiles_on_break"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "wall_layer"
    value: "solid"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "broken_wall_layer"
    value: "broken_wall"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "swap_width"
    value: "64.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "swap_height"
    value: "64.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "show_sprite"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
}
components {
  id: "break_effect"
  component: "/developer/assets/fx/hit_impact.particlefx"
}
embedded_components {
  id: "sprite"
  type: "sprite"
  data: "default_animation: \"breakable_wall_idle\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/developer/assets/atlas/gameplay_visuals.atlas\"\n"
  "}\n"
  ""
}
embedded_components {
  id: "hit_sound"
  type: "sound"
  data: "sound: \"/developer/assets/sfx/wall_hit.wav\"\n"
  "group: \"sfx\"\n"
  ""
}
embedded_components {
  id: "break_sound"
  type: "sound"
  data: "sound: \"/developer/assets/sfx/wall_break.wav\"\n"
  "group: \"sfx\"\n"
  ""
}
embedded_components {
  id: "collision"
  type: "collisionobject"
  data: "type: COLLISION_OBJECT_TYPE_STATIC\n"
  "mass: 0.0\n"
  "friction: 0.1\n"
  "restitution: 0.5\n"
  "group: \"world\"\n"
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
  "  data: 10.0\n"
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
  "  data: 10.0\n"
  "}\n"
  ""
}
