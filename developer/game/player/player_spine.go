components {
  id: "script"
  component: "/mvtk/player/player.script"
}
components {
  id: "visual_mode"
  component: "/developer/game/player/player_visual_mode.script"
  properties {
    id: "has_sprite"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
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
    id: "disable_unused_visual"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "defer_initial_play"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
}
