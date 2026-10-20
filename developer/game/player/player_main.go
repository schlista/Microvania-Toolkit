components {
  id: "script"
  component: "/mvtk/player/player.script"
}
components {
  id: "visual_mode"
  component: "/developer/game/player/player_visual_mode.script"
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
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "spine_id"
    value: "spine_visual#spine"
    type: PROPERTY_TYPE_URL
  }
  properties {
    id: "default_state"
    value: "idle"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "spine_blend"
    value: "0.08"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "auto_resolve_player_type"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "defer_initial_play"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
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
