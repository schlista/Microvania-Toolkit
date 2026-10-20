# Fonts

`fredoka.font` is the label font for the Layout Editor's room names and the
progression panel (GUI font name `room_label`). Everything else uses Defold's
built-in fonts.

`Fredoka-Medium.ttf` is Fredoka by Milena Brandão and Hafontia, licensed under
the SIL Open Font License 1.1 (`Fredoka-OFL.txt`). It is a static instance of
the variable `Fredoka[wdth,wght].ttf` from Google Fonts
(https://github.com/google/fonts/tree/main/ofl/fredoka), made with the
fontTools instancer at `wdth=90`, `wght=500`, so its text width and stroke
weight match the previous label font.

Keep `Fredoka-OFL.txt` next to the font file. To use another font, add its
`.ttf` or `.otf` here with its license and change `font:` in `fredoka.font`.
