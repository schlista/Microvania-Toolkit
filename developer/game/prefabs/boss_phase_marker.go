components {
  id: "script"
  component: "/mvtk/prefabs/boss_phase_marker.script"
  properties {
    id: "boss_type"
    value: "default_boss"
    type: PROPERTY_TYPE_TEXT
  }
  properties {
    id: "phase"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "health_min"
    value: "-1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "health_max"
    value: "-1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "attack_interval_min"
    value: "2.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "attack_interval_max"
    value: "4.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "speed_multiplier"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "damage_multiplier"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "transition_flash"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "transition_arena_darkness"
    value: "false"
    type: PROPERTY_TYPE_BOOLEAN
  }
}
