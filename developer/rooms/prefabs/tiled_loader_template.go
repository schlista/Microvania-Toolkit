components {
  id: "tiled_room_loader"
  component: "/mvtk/tiled/tiled_room_loader.script"
  properties {
    id: "room_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "auto_tile_animations"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "skip_spawn_types"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
}
