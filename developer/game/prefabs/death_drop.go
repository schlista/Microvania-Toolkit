components {
  id: "script"
  component: "/mvtk/prefabs/death_drop.script"
}
components {
  id: "particles"
  component: "/developer/assets/fx/collectible_sparkle.particlefx"
}
components {
  id: "collect_particles"
  component: "/developer/assets/fx/collectible_sparkle.particlefx"
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
  data: "collision_shape: \"\"\n"
  "type: COLLISION_OBJECT_TYPE_TRIGGER\n"
  "mass: 0.0\n"
  "friction: 0.1\n"
  "restitution: 0.1\n"
  "group: \"sensor\"\n"
  "mask: \"player\"\n"
  "embedded_collision_shape {\n"
  "  shapes {\n"
  "    shape_type: TYPE_SPHERE\n"
  "    position { x: 0.0 y: 0.0 z: 0.0 }\n"
  "    rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }\n"
  "    index: 0\n"
  "    count: 1\n"
  "    id: \"pickup\"\n"
  "  }\n"
  "  data: 16.0\n"
  "}\n"
  "locked_rotation: true\n"
  ""
}
