components {
  id: "sprite"
  component: "/developer/assets/sprites/boss.sprite"
  position {
    x: 0.0
    y: 0.0
    z: 0.0
  }
  rotation {
    x: 0.0
    y: 0.0
    z: 0.0
    w: 1.0
  }
}
components {
  id: "animation_controller"
  component: "/mvtk/animation/animation_controller.script"
  position {
    x: 0.0
    y: 0.0
    z: 0.0
  }
  rotation {
    x: 0.0
    y: 0.0
    z: 0.0
    w: 1.0
  }
  properties {
    id: "use_spine"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "sprite_id"
    value: "#sprite"
    type: PROPERTY_TYPE_URL
  }
  properties {
    id: "default_state"
    value: "idle"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "flip_by_scale"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
}
