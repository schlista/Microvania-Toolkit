components {
  id: "script"
  component: "/mvtk/prefabs/conveyor.script"
  properties {
    id: "show_sprite"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
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
  id: "collisionobject"
  type: "collisionobject"
  data: "type: COLLISION_OBJECT_TYPE_TRIGGER\n"
  "mass: 0.0\n"
  "friction: 0.0\n"
  "restitution: 0.0\n"
  "group: \"surface\"\n"
  "mask: \"player\"\n"
  "mask: \"enemy\"\n"
  "embedded_collision_shape {\n"
  "  shapes {\n"
  "    shape_type: TYPE_BOX\n"
  "    position { x: 0.0 y: 0.0 z: 0.0 }\n"
  "    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\n"
  "    index: 0\n"
  "    count: 3\n"
  "  }\n"
  "  data: 64.0\n"
  "  data: 8.0\n"
  "  data: 5.0\n"
  "}\n"
  ""
}
