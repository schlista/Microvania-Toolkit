# Input Bindings

`game.input_binding` is used by gameplay and the Layout Editor. Double-click it
in Defold to edit keyboard, mouse, touch, or gamepad bindings. Its physical
actions are device-separated: keyboard input uses `key_*`, while standard
controller input uses `gamepad_*`. Keep those IDs in sync with the `inputs`
allowlist and high-level `actions` table in
`developer/config/default_bindings.lua`.

The default map-display controls are **M** and **R3** (press the right
thumbstick). Either cycles between no map, the minimap panel, and the
full-screen map.

The project targets Defold 1.14.0's SDL controller database. Stick directions
use `gamepad_lstick_*` / `gamepad_rstick_*` actions and retain `action.value`;
the first mapped controller is selected by `action.gamepad` and identified by
its GUID metadata. Unmapped devices remain diagnostic-only and cannot claim
gameplay. The hardware deadzone is set once as `input.gamepad_deadzone` in
`game.project`. Do not add a project `.gamepads` file or a second Lua deadzone.

Runtime remaps are stored as a current-only versioned payload. Older binding
save formats and action aliases are intentionally not migrated. Controller
remapping changes only the selected physical controller binding, preserves the
keyboard bindings for that action, and gives each controller button one owner.

See **[the complete creator guide](../../docs/CREATOR_WORKFLOW.html#controls-and-input)**.
