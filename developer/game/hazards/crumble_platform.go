components {
  id: "script"
  component: "/mvtk/hazards/crumble_platform.script"
}
embedded_components {
  id: "co"
  type: "collisionobject"
  data: "collision_shape: \"\"\n"
  "type: COLLISION_OBJECT_TYPE_KINEMATIC\n"
  "mass: 0.0\n"
  "friction: 0.0\n"
  "restitution: 0.0\n"
  "group: \"solid\"\n"
  "mask: \"player\"\n"
  "embedded_collision_shape { shapes { shape_type: TYPE_BOX position { x: 0.0 y: 0.0 z: 0.0 } rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 } index: 0 count: 3 } data: 64.0 data: 16.0 data: 10.0 }\n"
  "locked_rotation: true\n"
  ""
}
