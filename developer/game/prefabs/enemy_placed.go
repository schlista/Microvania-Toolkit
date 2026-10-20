components {
  id: "enemy"
  component: "/mvtk/enemies/enemy.script"
}
components {
  id: "anim"
  component: "/mvtk/animation/animation_controller.script"
  properties {
    id: "default_state"
    value: "default__idle"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "sprite_atlas"
    value: "/developer/assets/atlas/enemy.atlas"
    type: PROPERTY_TYPE_TEXT
  }
}
components {
  id: "sprite"
  component: "/developer/assets/enemies/generated/default.sprite"
}
components {
  id: "co"
  component: "/developer/game/enemies/collisionobject.collisionobject"
}
embedded_components {
  id: "loot_factory"
  type: "factory"
  data: "prototype: \"/developer/game/prefabs/loot_coin.go\"\n"
  ""
}
