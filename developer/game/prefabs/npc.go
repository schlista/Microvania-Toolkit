components {
  id: "npc"
  component: "/mvtk/prefabs/npc.script"
  properties {
    id: "npc_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "npc_type"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "npc_name"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "npc_sprite"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "dialogue_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "facing"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "interaction_range"
    value: "48.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "room_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "despawn_flag"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
}
embedded_components {
  id: "sprite"
  type: "sprite"
  data: "default_animation: \"npc_idle\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/developer/assets/atlas/gameplay_visuals.atlas\"\n"
  "}\n"
  ""
}
