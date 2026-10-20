components {
  id: "script"
  component: "/mvtk/prefabs/tile_platform.script"
  properties {
    id: "platform_type"
    value: "horizontal"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "path_dx"
    value: "200.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "path_dy"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "duration"
    value: "2.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "wait"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "width"
    value: "128.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "height"
    value: "128.0"
    type: PROPERTY_TYPE_NUMBER
  }
}
components {
  id: "tilemap"
  component: "/developer/game/prefabs/tile_moving_platform.tilemap"
}
