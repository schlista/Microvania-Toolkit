components {
  id: "boss"
  component: "/mvtk/bosses/boss.script"
  properties {
    id: "boss_type"
    value: "foundry_boss"
    type: PROPERTY_TYPE_TEXT
  }
}
components {
  id: "sprite"
  component: "/developer/assets/sprites/boss.sprite"
}
components {
  id: "sprite_test"
  component: "/developer/assets/sprites/test_boss_placeholder.sprite"
}
components {
  id: "sprite_gate_warden"
  component: "/developer/assets/sprites/gate_warden_placeholder.sprite"
}
components {
  id: "sprite_sky_tyrant"
  component: "/developer/assets/sprites/sky_tyrant_placeholder.sprite"
}
components {
  id: "sprite_arena_sentinel"
  component: "/developer/assets/sprites/arena_sentinel_placeholder.sprite"
}
components {
  id: "sprite_cactus_boss"
  component: "/developer/assets/sprites/cactus_boss.sprite"
  position {
    y: 96.0
  }
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
    id: "spine_id"
    value: "#spine"
    type: PROPERTY_TYPE_URL
  }
  properties {
    id: "default_state"
    value: "idle"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "sprite_atlas"
    value: "/developer/assets/atlas/boss.atlas"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "defer_initial_play"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "spine_blend"
    value: "0.08"
    type: PROPERTY_TYPE_NUMBER
  }
}
embedded_components {
  id: "boss_projectile_factory"
  type: "factory"
  data: "prototype: \"/developer/game/attacks/enemy_projectile.go\"\n"
  ""
}
embedded_components {
  id: "melee_hitbox_factory"
  type: "factory"
  data: "prototype: \"/developer/game/attacks/melee_hitbox.go\"\n"
  ""
}
embedded_components {
  id: "telegraph_factory"
  type: "factory"
  data: "prototype: \"/developer/game/prefabs/boss_telegraph.go\"\n"
  ""
}
embedded_components {
  id: "aoe_effect_factory"
  type: "factory"
  data: "prototype: \"/developer/game/prefabs/boss_aoe_effect.go\"\n"
  ""
}
embedded_components {
  id: "collision"
  type: "collisionobject"
  data: "type: COLLISION_OBJECT_TYPE_KINEMATIC\n"
  "mass: 0.0\n"
  "friction: 0.1\n"
  "restitution: 0.1\n"
  "group: \"enemy\"\n"
  "mask: \"attack\"\n"
  "mask: \"world\"\n"
  "mask: \"player\"\n"
  "embedded_collision_shape {\n"
  "  shapes {\n"
  "    shape_type: TYPE_BOX\n"
  "    position { }\n"
  "    rotation { }\n"
  "    index: 0\n"
  "    count: 3\n"
  "  }\n"
  "  data: 64.0\n"
  "  data: 64.0\n"
  "  data: 10.0\n"
  "}\n"
  "locked_rotation: true\n"
  ""
}
