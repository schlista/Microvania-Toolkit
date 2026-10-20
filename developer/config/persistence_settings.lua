-- Project > Game Settings... assigns each new game a permanent save ID on its first Save.
-- Renames and working copies retain it; set it to "" in a copy to make a different game.
-- shared_titles: toolkit placeholder names that trigger the rename warning on Save.
return {
    game_id = "",
    shared_titles = { "microvania toolkit", "metroidvania toolkit", "mv_toolkit" },
}
