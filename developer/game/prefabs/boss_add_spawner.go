components {
  id: "script"
  component: "/mvtk/prefabs/boss_add_spawner.script"
  properties {
    id: "spawn_interval"
    value: "4.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "spawn_count"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "spawn_radius"
    value: "120.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "max_alive"
    value: "3.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "max_total"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "start_delay"
    value: "0.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "start_active"
    value: "true"
    type: PROPERTY_TYPE_BOOLEAN
  }
  properties {
    id: "health_mult"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "damage_mult"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
  properties {
    id: "speed_mult"
    value: "1.0"
    type: PROPERTY_TYPE_NUMBER
  }
}
