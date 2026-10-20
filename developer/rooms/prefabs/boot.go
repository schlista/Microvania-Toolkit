components {
  id: "room_boot"
  component: "/developer/rooms/prefabs/room_boot.script"
}
components {
  id: "player_factory"
  component: "/developer/game/player/player_factory.collectionfactory"
}
components {
  id: "player_spine_factory"
  component: "/developer/game/player/player_spine_factory.collectionfactory"
}
components {
  id: "player_sprite_factory"
  component: "/developer/game/player/player_sprite_factory.collectionfactory"
}
embedded_components {
  id: "grapple_anchor_factory"
  type: "factory"
  data: "prototype: \"/developer/rooms/prefabs/grapple_anchor.go\"\n"
  ""
}
