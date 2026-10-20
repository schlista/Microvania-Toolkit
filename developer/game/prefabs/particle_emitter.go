components {
  id: "script"
  component: "/mvtk/prefabs/particle_emitter.script"
  properties {
    id: "emitter_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "effect_id"
    value: ""
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "auto_play"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "loop"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "loop_interval"
    value: "0.5"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "start_delay"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "run_duration"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "debug_marker"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "debug_follow_player"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
}
components {
  id: "particlefx"
  component: "/developer/assets/fx/ambient_sparkle.particlefx"
}
embedded_components {
  id: "debug_marker"
  type: "sprite"
  data: "default_animation: \"prop_base\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/developer/assets/atlas/gameplay_visuals.atlas\"\n"
  "}\n"
  ""
}
