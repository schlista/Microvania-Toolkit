components {
  id: "script"
  component: "/mvtk/prefabs/boss_weak_point.script"
  properties {
    id: "damage_mult"
    value: "2.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "health"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "exposed_in_phase"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "hidden_in_phase"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "vulnerable"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "show_sprite"
    value: "true"
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
    y: 0.5
    z: 1.0
  }
}
embedded_components {
  id: "co"
  type: "collisionobject"
  data: "type: COLLISION_OBJECT_TYPE_TRIGGER\n"
  "mass: 0.0\n"
  "friction: 0.0\n"
  "restitution: 0.0\n"
  "group: \"enemy\"\n"
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
