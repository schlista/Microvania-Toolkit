components {
  id: "collisionobject"
  component: "/developer/game/player/bone_colliders/body_hurtbox.collisionobject"
}
components {
  id: "bone_collider"
  component: "/developer/game/player/bone_colliders/bone_collider.script"
  properties {
    id: "part_id"
    value: "body"
    type: PROPERTY_TYPE_TEXT
  }
}
