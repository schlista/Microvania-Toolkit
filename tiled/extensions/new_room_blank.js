/*
 * One-click blank room generator for MV Toolkit.
 *
 * Creates a new TMX map with the toolkit's expected room structure:
 * - map properties: biome, darkness, room_zone, music
 * - top-level layers: bounds, grapple, solid (collision tiles), templates
 * - exit group: door_left, door_right, door_top, door_bottom
 * - locked doors are authored as rectangle objects with the locked_door template
 * - art group: background/foreground layers and object groups
 */

(function () {
    // A global copy (INSTALL.bat / INSTALL.sh / the Windows installer) and the
    // project copy can both load into the same script engine when
    // MVTK.tiled-project is open, in either order: Tiled loads extension
    // folders sorted by path. The newest copy publishes the room builder
    // (MVTKNewRoom, used by File > Start a New World...) and registers the
    // File-menu action; an equal or older copy of this version scheme loaded
    // later leaves both alone, and claimLegacyGuard() stops copies from
    // earlier toolkits. Re-registering replaces the action and its menu entry,
    // so the item never appears twice.
    var _g = (typeof globalThis !== "undefined") ? globalThis : this;
    var builderVersion = 6;

    function normalizePath(path) {
        return String(path || "").replace(/\\/g, "/");
    }

    function ensureExt(path, ext) {
        var normalized = normalizePath(path);
        if (!normalized) return normalized;
        var suffix = String(ext || "");
        if (!suffix) return normalized;
        if (normalized.toLowerCase().slice(-suffix.length) === suffix.toLowerCase()) {
            return normalized;
        }
        return normalized + suffix;
    }

    function absoluteProjectFolder(folder) {
        var normalized = normalizePath(folder);
        if (!normalized) return "";
        if (FileInfo.isAbsolutePath(normalized)) {
            return FileInfo.cleanPath(normalized);
        }

        var projectPath = normalizePath(tiled.projectFilePath || "");
        if (!projectPath) {
            return FileInfo.cleanPath(normalized);
        }

        return FileInfo.cleanPath(FileInfo.joinPaths(FileInfo.path(projectPath), normalized));
    }

    function guessDefaultMapDir() {
        var api = _g.MVTKMapExport;
        var root = api && api.root();
        var asset = tiled.activeAsset;
        if (asset && asset.isTileMap && asset.fileName && root && !api.insideRoot(asset.fileName, root)) {
            return FileInfo.path(normalizePath(asset.fileName));
        }

        var project = tiled.project;
        var folders = (project && project.folders) || [];
        var i = 0;
        for (i = 0; i < folders.length; i++) {
            var folder = absoluteProjectFolder(folders[i]);
            if (!folder) continue;
            if (!root || api.insideRoot(folder, root)) continue;
            if (/\/maps$/i.test(folder)) {
                return folder;
            }
            return FileInfo.cleanPath(FileInfo.joinPaths(folder, "maps"));
        }

        return "";
    }

    function readTextFile(path) {
        try {
            var file = new TextFile(path, TextFile.ReadOnly);
            var text = file.readAll();
            file.close();
            return String(text || "");
        } catch (e) {
            return "";
        }
    }

    function loadTileSettings() {
        var fallback = { width: 128, height: 128 };
        var projectPath = normalizePath(tiled.projectFilePath || "");
        if (!projectPath) {
            return fallback;
        }

        var currentDir = FileInfo.path(projectPath);
        var depth = 0;
        while (currentDir && depth < 6) {
            var candidate = FileInfo.cleanPath(
                FileInfo.joinPaths(currentDir, "developer/config/tile_settings.lua")
            );
            var text = readTextFile(candidate);
            if (text) {
                var widthMatch = text.match(/width\s*=\s*(\d+)/);
                var heightMatch = text.match(/height\s*=\s*(\d+)/);
                var width = widthMatch ? parseInt(widthMatch[1], 10) : fallback.width;
                var height = heightMatch ? parseInt(heightMatch[1], 10) : width;
                if (width > 0 && height > 0) {
                    return { width: width, height: height };
                }
            }

            var parentDir = FileInfo.path(currentDir);
            if (!parentDir || parentDir === currentDir) {
                break;
            }
            currentDir = parentDir;
            depth += 1;
        }

        return fallback;
    }

    function parseRoomSize(text, defaultWidth, defaultHeight) {
        var raw = String(text || "");
        var trimmed = raw.replace(/^\s+|\s+$/g, "");
        var match = trimmed.match(/^(\d+)\s*[x, ]\s*(\d+)$/i);
        if (!match) {
            return null;
        }

        var width = parseInt(match[1], 10);
        var height = parseInt(match[2], 10);
        if (!width || !height || width <= 0 || height <= 0) {
            return null;
        }

        return {
            width: width || defaultWidth,
            height: height || defaultHeight
        };
    }

    function parseTileSize(text) {
        var trimmed = String(text || "").replace(/^\s+|\s+$/g, "");
        if (!trimmed) {
            return null;
        }

        // A single value means square tiles (16 -> 16x16).
        var single = trimmed.match(/^(\d+)$/);
        if (single) {
            var side = parseInt(single[1], 10);
            return side > 0 ? { width: side, height: side } : null;
        }

        var match = trimmed.match(/^(\d+)\s*[x, ]\s*(\d+)$/i);
        if (!match) {
            return null;
        }

        var width = parseInt(match[1], 10);
        var height = parseInt(match[2], 10);
        if (width <= 0 || height <= 0) {
            return null;
        }

        return { width: width, height: height };
    }

    function makeTileLayer(name) {
        return new TileLayer(name);
    }

    function makeObjectLayer(name) {
        var layer = new ObjectGroup(name);
        layer.drawOrder = ObjectGroup.TopDownOrder;
        return layer;
    }

    function addMapProperties(map) {
        map.setProperty("biome", tiled.propertyValue("biomes", "inherit"));
        map.setFloatProperty("darkness", 0.0);
        map.setProperty("room_zone", tiled.propertyValue("room_zones", "platforming"));

        // Room background music: the ONE control. This is a file property
        // pointing at an .ogg/.wav. Project > Create Rooms copies and wires it.
        // Empty means no override: whatever track is already playing continues.
        try {
            map.setProperty("music", tiled.filePath(""));
        } catch (e) {
            // Older Tiled builds may not expose tiled.filePath in scripts.
            // Fall back to a string; Sync Music uses the same value.
            map.setProperty("music", "");
        }
    }

    function addExitGroup(map) {
        var group = new GroupLayer("exit");
        group.addLayer(makeTileLayer("door_left"));
        group.addLayer(makeTileLayer("door_right"));
        group.addLayer(makeTileLayer("door_top"));
        group.addLayer(makeTileLayer("door_bottom"));
        map.addLayer(group);
    }

    function addArtGroup(map) {
        var group = new GroupLayer("art");

        group.addLayer(makeObjectLayer("background_far"));
        group.addLayer(makeObjectLayer("background"));
        group.addLayer(makeObjectLayer("background_near"));

        group.addLayer(makeTileLayer("background_far"));
        group.addLayer(makeTileLayer("background_near"));
        group.addLayer(makeTileLayer("environment"));
        group.addLayer(makeTileLayer("foreground_far"));
        group.addLayer(makeTileLayer("foreground_near"));

        group.addLayer(makeObjectLayer("foreground_far"));
        group.addLayer(makeObjectLayer("foreground"));
        group.addLayer(makeObjectLayer("foreground_near"));

        map.addLayer(group);
    }

    function addTemplatesLayer(map) {
        var layer = makeObjectLayer("templates");
        layer.className = "game_objects";
        map.addLayer(layer);
    }

    function buildRoomMap(width, height, tileWidth, tileHeight) {
        var map = new TileMap();
        map.orientation = TileMap.Orthogonal;
        map.renderOrder = TileMap.RightDown;
        map.layerDataFormat = TileMap.CSV;
        map.infinite = false;
        map.setSize(width, height);
        map.setTileSize(tileWidth, tileHeight);

        addMapProperties(map);
        map.addLayer(makeTileLayer("bounds"));
        map.addLayer(makeTileLayer("grapple"));
        // The Creator Guide's collision layer: paint tiles that have Tile
        // Collision Editor shapes here (any shaped tile on an art layer also
        // collides, and solid_box/solid_slope objects add more).
        map.addLayer(makeTileLayer("solid"));
        addExitGroup(map);
        addArtGroup(map);
        addTemplatesLayer(map);

        return map;
    }

    function writeMapToFile(map, filePath) {
        var format = tiled.mapFormatForFile(filePath);
        if (!format || typeof format.write !== "function") {
            return "Could not find a writable map format for:\n" + filePath;
        }

        File.makePath(FileInfo.path(filePath));
        try {
            var err = format.write(map, filePath);
            if (typeof err === "string" && err.length > 0) {
                return err;
            }
        } catch (e) {
            return String(e);
        }

        return null;
    }

    // Copies of this file from earlier toolkits stay in Tiled's global
    // extensions folder after INSTALL.bat, the Windows installer or
    // tools/set_tiled_export_path ran. Loaded after this copy, one would
    // re-register its own File > new_room_blank, which builds rooms without
    // the solid layer (or without grapple). Every such copy checks
    // __mvtkNewRoomBlankLoaded first: the released betas return when it is
    // set, later ones only when it equals their own number (2, 3 or 4) and
    // otherwise write that number before registering. Reading 4 stops all but
    // 2 and 3; refusing their write stops those two before they register
    // (Tiled logs the error below). Copies from before June 2026 had no check.
    function claimLegacyGuard() {
        try {
            Object.defineProperty(_g, "__mvtkNewRoomBlankLoaded", {
                configurable: true,
                get: function () { return 4; },
                set: function (value) {
                    throw new Error("Skipped an older copy of the toolkit's new_room_blank.js (" + value +
                        "); the newer File > new_room_blank stays registered.");
                }
            });
        } catch (e) {
            tiled.log("[MVTK] new_room_blank: could not guard against older copies: " + e);
        }
    }

    // The room builder for other toolkit commands (File > Start a New World...).
    if (!_g.MVTKNewRoom || _g.MVTKNewRoom.version < builderVersion) {
        _g.MVTKNewRoom = {
            version: builderVersion,
            build: buildRoomMap,
            write: writeMapToFile,
            tileSettings: loadTileSettings,
            parseRoomSize: parseRoomSize,
            parseTileSize: parseTileSize,
            defaultDir: guessDefaultMapDir
        };
    }
    if (_g.__mvtkNewRoomBlankVersion >= builderVersion) return;

    var action = tiled.registerAction("MVTK.new_room_blank", function () {
        try {
            var defaultSize = "53x44";
            var tile = loadTileSettings();

            var sizeText = tiled.prompt(
                "Room size in tiles (widthxheight)",
                defaultSize,
                "new_room_blank"
            );
            if (!sizeText) return;

            var size = parseRoomSize(sizeText, 53, 44);
            if (!size) {
                tiled.alert("Room size must look like 53x44.");
                return;
            }

            var defaultTile = (tile.width === tile.height)
                ? String(tile.width)
                : (tile.width + "x" + tile.height);
            var tileText = tiled.prompt(
                "Tile size in pixels (one value for square tiles, or widthxheight)",
                defaultTile,
                "new_room_blank tile size"
            );
            if (!tileText) return;

            var tileSize = parseTileSize(tileText);
            if (!tileSize) {
                tiled.alert("Tile size must be a number like 16, or look like 16x16.");
                return;
            }
            var tileWidth = tileSize.width;
            var tileHeight = tileSize.height;

            var savePath = tiled.promptSaveFile(
                guessDefaultMapDir(),
                "Tiled Maps (*.tmx)",
                "Save new_room_blank"
            );
            if (!savePath) return;

            savePath = ensureExt(savePath, ".tmx");
            var api = _g.MVTKMapExport;
            var root = api && api.root();
            if (!root || api.insideRoot(savePath, root)) {
                tiled.alert("Choose an authoring folder outside the Defold project. Internal folders hold exported copies and can be cleared by Reset Project.");
                return;
            }

            var map = buildRoomMap(size.width, size.height, tileWidth, tileHeight);
            var err = writeMapToFile(map, savePath);
            if (err) {
                tiled.alert("Failed to create room skeleton:\n" + err);
                return;
            }

            var opened = tiled.open(savePath);
            if (opened) {
                tiled.activeAsset = opened;
            }

            tiled.log("[MVTK] Created new_room_blank: " + savePath);
            tiled.alert(
                "Created new_room_blank:\n" + savePath +
                "\n\nWhen you're ready, use File > Export Current Room."
            );
        } catch (e) {
            tiled.alert("Failed to create room skeleton:\n" + e);
        }
    });

    action.text = "new_room_blank";
    action.shortcut = "Ctrl+Alt+N";

    // --evaluate has no menus (extendMenu would throw "Unknown menu"); the
    // action stays callable headlessly.
    if (tiled.menus.indexOf("File") >= 0) tiled.extendMenu("File", [
        { action: "MVTK.new_room_blank" }
    ]);
    // Marked only after a complete registration, so a failed one can retry.
    _g.__mvtkNewRoomBlankVersion = builderVersion;
    claimLegacyGuard();
})();
