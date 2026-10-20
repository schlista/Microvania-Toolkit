components {
  id: "script"
  component: "/mvtk/prefabs/pushable_block.script"
  properties {
    id: "block_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "room_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "reset_on_room_load"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "push_force"
    value: "2200.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "min_force_scale"
    value: "0.35"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "max_force_scale"
    value: "1.5"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "gravity_scale"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "move_embedded_tiles"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "capture_width"
    value: "128.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "capture_height"
    value: "128.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "debug_tile_chunk"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
}
components {
  id: "co"
  component: "/developer/game/prefabs/pushable_block.collisionobject"
}
embedded_components {
  id: "pushable_tag"
  type: "collisionobject"
  data: "collision_shape: \"\"\n"
  "type: COLLISION_OBJECT_TYPE_TRIGGER\n"
  "mass: 0.0\n"
  "friction: 0.0\n"
  "restitution: 0.0\n"
  "group: \"pushable\"\n"
  "mask: \"solid\"\n"
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
components {
  id: "chunk"
  component: "/developer/game/prefabs/pushable_tile_chunk.tilemap"
}
embedded_components {
  id: "sprite"
  type: "sprite"
  data: "tile_set: \"/developer/assets/atlas/gameplay_visuals.atlas\"\n"
  "default_animation: \"wall_base\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "blend_mode: BLEND_MODE_ALPHA\n"
  ""
}
