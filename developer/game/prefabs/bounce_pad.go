components {
  id: "script"
  component: "/mvtk/prefabs/bounce_pad.script"
  properties {
    id: "bounce_speed"
    value: "900.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "cooldown"
    value: "0.2"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "require_interact"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "label"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "sound_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "range"
    value: "80.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "show_sprite"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
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
  scale {
    x: 0.5
    y: 0.125
  }
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
  "  data: 16.0\n"
  "  data: 10.0\n"
  "}\n"
  ""
}
