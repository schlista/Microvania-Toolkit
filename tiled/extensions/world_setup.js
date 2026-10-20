/*
 * World setup command for MV Toolkit (File menu, Tiled 1.11+):
 *
 * - Start a New World...  creates a world folder with a .world file and its
 *   first blank room (the same skeleton as File > new_room_blank), then opens it.
 *
 * Sample worlds need no command of their own: a creator opens a downloaded
 * sample's .world with File > Open File or Project..., exactly like a world of
 * their own. Everything here uses Tiled's own script API, so the command
 * behaves the same on Windows, macOS and Linux with nothing to install.
 */

(function () {
    // A global copy and the project copy can share one script engine; the newest
    // copy registers (re-registering an action replaces it, so the menu item is
    // attached again below).
    var _g = (typeof globalThis !== "undefined") ? globalThis : this;
    var version = 5;
    if (_g.MVTKWorldSetup && _g.MVTKWorldSetup.version >= version) return;

    function normalizePath(path) {
        return String(path || "").replace(/\\/g, "/").replace(/\/+$/, "");
    }

    function join(dir, name) {
        return normalizePath(dir) + "/" + String(name || "").replace(/^\/+/, "");
    }

    function parentOf(path) {
        var n = normalizePath(path);
        var i = n.lastIndexOf("/");
        return i > 0 ? n.slice(0, i) : n;
    }

    function exporter() {
        var api = _g.MVTKMapExport;
        if (!api || !api.root) {
            throw new Error(
                "The toolkit's Tiled extensions did not load. Open MVTK.tiled-project " +
                "(File > Open File or Project...), click Enable Extensions if Tiled asks, and " +
                "check the Tiled Console for errors in tiled/extensions."
            );
        }
        return api;
    }

    // The toolkit whose Tiled project is open. Unlike exporting, this command
    // never falls back to export_path.txt: it writes a hint into the toolkit, so
    // it must be the one the creator opened.
    function toolkitRoot() {
        var api = exporter();
        var root = normalizePath(api.projectRoot ? api.projectRoot() : api.root());
        if (!root) {
            throw new Error(
                "Open your toolkit's Tiled project first: File > Open File or Project... and pick " +
                "MVTK.tiled-project in the toolkit folder (the folder that holds game.project)."
            );
        }
        return root;
    }

    function insideToolkit(path, root) {
        return !!exporter().insideRoot(path, root);
    }

    // "My Cave World" -> "my_cave_world" (room and world file ids).
    function slug(name) {
        return String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
    }

    // Folder name: the typed name with underscores for spaces (like the sample
    // packs' world folders) and without characters Windows, macOS or Linux reject.
    function folderName(name) {
        return String(name || "").replace(/[\\/:*?"<>|]+/g, " ").replace(/^[\s.]+|[\s.]+$/g, "").replace(/\s+/g, "_");
    }

    // Create destinationParent/<Name>/<name>.world with its first blank room in
    // rooms/<name>_01.tmx. room and tile are { width, height } (tiles / pixels).
    function startWorld(name, destinationParent, room, tile) {
        var root = toolkitRoot();
        var id = slug(name), folder = folderName(name);
        if (!id || !folder) throw new Error("Give the world a name with at least one letter or digit.");
        var builder = _g.MVTKNewRoom;
        if (!builder || !builder.build || !builder.write) {
            throw new Error("The new room builder did not load (tiled/extensions/new_room_blank.js).");
        }
        var destination = join(destinationParent, folder);
        if (insideToolkit(destination, root)) {
            throw new Error("Choose a folder outside the toolkit.\n\n" + destination + "\nis inside\n" + root);
        }
        var worldPath = join(destination, id + ".world");
        if (File.exists(worldPath)) throw new Error("A world already exists there:\n" + worldPath);
        var roomFile = "rooms/" + id + "_01.tmx";
        var mapPath = join(destination, roomFile);
        var firstRoom = builder.build(room.width, room.height, tile.width, tile.height);
        // File > Export All Maps and Tiled World needs exactly one world map marked
        // as the starting room; rooms added later with new_room_blank are not.
        firstRoom.setProperty("is_starting_room", true);
        var error = builder.write(firstRoom, mapPath);
        if (error) throw new Error("Could not create the first room:\n" + error);
        var world = {
            type: "world",
            onlyShowAdjacentMaps: false,
            maps: [{ fileName: roomFile, x: 0, y: 0,
                     width: room.width * tile.width, height: room.height * tile.height }],
            properties: [{ name: "world_name", type: "string", value: String(name) }]
        };
        exporter().write(worldPath, JSON.stringify(world, null, 2) + "\n");
        return { root: root, destination: destination, world: worldPath, room: mapPath, id: id };
    }

    // Load the world and open its room so the creator can start right away.
    function openWorld(worldPath, mapPath) {
        if (typeof tiled.loadWorld === "function") tiled.loadWorld(worldPath);
        if (mapPath && File.exists(mapPath)) {
            var asset = tiled.open(mapPath);
            if (asset) tiled.activeAsset = asset;
        }
    }

    // Default folder for the world: the first Project-panel folder outside the
    // toolkit (Project > Set Up This Toolkit in Defold adds one), else the
    // folder that holds the toolkit.
    function defaultWorldsFolder(root) {
        var project = tiled.project;
        var folders = (project && project.folders) || [];
        var projectDir = parentOf(normalizePath(tiled.projectFilePath || ""));
        for (var i = 0; i < folders.length; i++) {
            var folder = normalizePath(folders[i]);
            if (!folder) continue;
            if (!(typeof FileInfo !== "undefined" && FileInfo.isAbsolutePath(folder))) {
                folder = normalizePath(FileInfo.cleanPath(FileInfo.joinPaths(projectDir, folder)));
            }
            if (!insideToolkit(folder, root)) return folder;
        }
        return parentOf(root);
    }

    function worldsFolderPath(folder) {
        var path = normalizePath(folder);
        // A directory picker may return a drive root or the Unix root. Keep
        // these absolute when stripping an ordinary directory's trailing slash.
        return /^[A-Za-z]:$/.test(path) ? path + "/" : (path || "/");
    }

    // Project.folders is read-only in Tiled. Leave a small handoff for Defold's
    // Set Up command instead; failure to remember it must not undo a good world.
    function rememberWorldsFolder(result, destinationParent, kind) {
        var hintPath = join(result.root, "TILED_WORLDS_FOLDER.txt");
        try {
            exporter().write(hintPath,
                "# Written by Tiled's File > Start a New World...\n" +
                "# Defold's Project > Set Up This Toolkit offers this folder. Safe to delete.\n" +
                "folder=" + worldsFolderPath(destinationParent) + "\n" +
                "world=" + normalizePath(result.world) + "\n" +
                "kind=" + kind + "\n");
        } catch (e) {
            tiled.log("[MVTK] Warning: could not remember your worlds folder in " + hintPath +
                ": " + String(e && e.message ? e.message : e));
        }
    }

    function setupDirections(destinationParent) {
        return "In Defold: open the toolkit, then Project > Set Up This Toolkit.\n" +
            "It offers your worlds folder: " + worldsFolderPath(destinationParent) + ".\n" +
            "Click Set Up, then Project > Reload Editor Scripts";
    }

    function startNewWorldCommand() {
        try {
            var root = toolkitRoot();
            var builder = _g.MVTKNewRoom;
            if (!builder) throw new Error("The new room builder did not load (tiled/extensions/new_room_blank.js).");

            var name = tiled.prompt("World name", "My World", "Start a New World");
            if (!name) return;
            if (!slug(name)) { tiled.alert("Give the world a name with at least one letter or digit."); return; }

            var sizeText = tiled.prompt("First room size in tiles (widthxheight)", "30x17", "Start a New World");
            if (!sizeText) return;
            var room = builder.parseRoomSize(sizeText, 30, 17);
            if (!room) { tiled.alert("Room size must look like 30x17."); return; }

            var tileDefault = builder.tileSettings();
            var tileText = tiled.prompt(
                "Tile size in pixels (one value for square tiles, or widthxheight)",
                tileDefault.width === tileDefault.height ? String(tileDefault.width)
                    : tileDefault.width + "x" + tileDefault.height,
                "Start a New World"
            );
            if (!tileText) return;
            var tile = builder.parseTileSize(tileText);
            if (!tile) { tiled.alert("Tile size must be a number like 16, or look like 16x16."); return; }

            var destinationParent = tiled.promptDirectory(
                defaultWorldsFolder(root),
                "Start a New World: choose where to create the world folder (outside the toolkit)"
            );
            if (!destinationParent) return;

            var result = startWorld(name, destinationParent, room, tile);
            openWorld(result.world, result.room);
            rememberWorldsFolder(result, destinationParent, "new");
            tiled.log("[MVTK] Start a New World: " + result.world);
            tiled.alert(
                "Created the world:\n  " + result.world + "\nwith its first room:\n  " + result.room +
                "\n\n" + setupDirections(destinationParent) + ".\n" +
                "\nThis room is blank and not playable yet. Continue with the Creator Guide's\n" +
                "section 4, using this room as your start room: add your tileset (Map > Add\n" +
                "External Tileset...), paint the art, bounds, solid and door layers, and place a\n" +
                "player_start. Make more rooms with File > new_room_blank in the same rooms folder.",
                "Start a New World"
            );
        } catch (e) {
            tiled.alert(String(e && e.message ? e.message : e), "Start a New World");
        }
    }

    var startAction = tiled.registerAction("MVTK.StartNewWorld", startNewWorldCommand);
    startAction.text = "Start a New World...";
    // Re-registering replaces the QAction and removes its old menu entry, so
    // attach the replacement too. --evaluate has no menus; the API below stays
    // usable headlessly.
    if (tiled.menus.indexOf("File") >= 0) tiled.extendMenu("File", [
        { separator: true },
        { action: "MVTK.StartNewWorld" }
    ]);

    // Published last, so a copy whose registration failed can be retried.
    _g.MVTKWorldSetup = {
        version: version,
        startWorld: startWorld,
        slug: slug,
        folderName: folderName
    };
})();
