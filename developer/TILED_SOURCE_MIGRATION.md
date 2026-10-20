# Tiled authoring sources

The current test content's originals are in `V:/Microvania_Test_Toolkit_Assests/`:

- `maps/`: 33 TMX rooms, the 27-room Tiled world, and its playtest guide.
- `tilesets/`: four TSX tilesets.
- `backgrounds/` and `tilesheets/`: source artwork, including unused images.
- `migration-verification.json`: SHA-256 records for the 80 relocated files.

Open the toolkit's root `MVTK.tiled-project` to load its extensions and property
types. Its sidebar now points to the external folders. Open the external
`maps/pt4_template_tour.world` to continue editing the current world.

The files under `developer/assets/` are retained as exported copies required by
Defold. `.mvtk-source` files record each copy's external original and exported
fingerprint. Do not edit or delete these receipts manually. Export refreshes
them, and Reset Project checks them before moving any files.

Framework templates under `tiled/templates/` stay in the toolkit and survive
reset. Maps reference these templates directly; all room art and tilesets now
reference external originals.

After this migration, restart Tiled and Defold to clear their open documents and
cached editor modules. Open the external originals rather than old internal tabs.
Run Import Assets, Create Rooms, Validate All, then Build in Defold. The migration
was checked with Tiled's native CLI exporter and a read-only reset preflight;
the Defold editor workflow and visual playtest still need an in-engine check.
