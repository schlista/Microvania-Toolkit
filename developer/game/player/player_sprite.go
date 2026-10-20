components {
  id: "script"
  component: "/mvtk/player/player.script"
}
components {
  id: "co"
  component: "/developer/game/player/collisionobject.collisionobject"
}
components {
  id: "grapple_rope"
  component: "/developer/assets/sprites/grapple_rope.sprite"
}
components {
  id: "anim"
  component: "/mvtk/animation/animation_controller.script"
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
}
embedded_components {
  id: "sprite"
  type: "sprite"
  data: "default_animation: \"idle\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/developer/assets/atlas/player.atlas\"\n"
  "}\n"
  "size {\n"
  "  x: 240.0\n"
  "  y: 136.0\n"
  "}\n"
  "size_mode: SIZE_MODE_MANUAL\n"
  position {
    y: -7.48
  }
}
