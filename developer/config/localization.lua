-- developer/config/localization.lua
-- Basic localization table; extend with more locales/keys.
--
-- ## Adding a locale
-- 1. Add a sibling key under `locales = { ... }` whose key is the locale
--    code (e.g. "fr", "ja", "pt-br").
-- 2. Mirror the existing `ui` structure so every key resolves.
--    Missing keys silently fall back to `default_locale`, which is fine
--    during translation but means the UI will show English placeholders
--    until the entry is filled in.
-- 3. Switch the active locale at runtime by setting Localization.locale to
--    the new key (see mvtk/core/localization.lua).
--
-- Example minimal French locale:
--   fr = {
--       ui = {
--           tutorial_jump        = "Appuyez sur ESPACE pour sauter",
--           tutorial_dash        = "Appuyez sur MAJ pour faire un dash",
--       },
--   }

return {
    default_locale = "en",
    locales = {
        en = {
            ui = {
                tutorial_jump = "Press SPACE to jump",
                tutorial_dash = "Press SHIFT to dash",
            },
        },
        es = {
            ui = {
                tutorial_jump = "Pulsa ESPACIO para saltar",
            },
        }
    }
}
