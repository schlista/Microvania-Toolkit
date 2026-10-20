/*
 * One-click export for MV Toolkit maps:
 * - <room>.lua
 * - <room>.tilemap
 * - <room>.tmx (generated project-local copy for external source maps)
 *
 * Exports are always written to:
 *   <repo>/developer/assets/tiled/maps/
 */

(function () {
    // Global installer and project extensions share one script engine. An old
    // global copy sets the legacy boolean without providing world export, so
    // only a fully initialized, compatible API may suppress this newer copy.
    var _g = (typeof globalThis !== "undefined") ? globalThis : this;
    // 10: the open toolkit project decides the export root (see detectProjectRoot),
    // so this copy must replace an older global copy that still prefers the
    // installer's global export_path.txt.
    // 11: refused writes are retried (writeWithRetry), so this copy must replace
    // an older global copy whose exports fail on a brief Windows file lock.
    var apiVersion = 11;
    if (_g.MVTKMapExport && _g.MVTKMapExport.version >= apiVersion) return;

    // An evaluation script may trigger this same File-menu action to export a
    // deterministic batch of fixture maps. Only that explicit mode suppresses
    // modal UI; interactive creator exports retain their normal dialogs.
    function alertUser(message, title) {
        if (_g && _g.__mvtkBatchExportQuiet) {
            tiled.log("[MVTK batch export] " + String(message || "").replace(/\n/g, " | "));
            return;
        }
        tiled.alert(message, title);
    }

    function reportExportFailure(message) {
        if (_g) _g.__mvtkLastExportError = String(message || "Export failed");
        alertUser(message, "Export failed");
    }

    function normalizePath(path) {
        return (path || "").replace(/\\/g, "/");
    }

    function cleanPath(path) {
        var normalized = normalizePath(path);
        if (typeof FileInfo !== "undefined" && typeof FileInfo.cleanPath === "function") {
            try { return normalizePath(FileInfo.cleanPath(normalized)); }
            catch (e) { /* fall back to the normalized spelling */ }
        }
        return normalized;
    }

    function pathKey(path) {
        var cleaned = cleanPath(path).replace(/\/+$/, "");
        // Tiled is running on Windows for the supported creator workflow, where
        // drive-letter paths are case-insensitive.
        return /^[A-Za-z]:\//.test(cleaned) ? cleaned.toLowerCase() : cleaned;
    }

    function isAbsolutePath(path) {
        var normalized = normalizePath(path);
        if (typeof FileInfo !== "undefined" && typeof FileInfo.isAbsolutePath === "function") {
            try { return FileInfo.isAbsolutePath(normalized); }
            catch (e) { /* use the portable fallback below */ }
        }
        return /^[A-Za-z]:\//.test(normalized) || normalized.charAt(0) === "/";
    }

    function resolvePath(baseDir, path) {
        var normalized = propertyToString(path);
        if (isAbsolutePath(normalized)) return cleanPath(normalized);
        if (typeof FileInfo !== "undefined" && typeof FileInfo.joinPaths === "function") {
            return cleanPath(FileInfo.joinPaths(baseDir, normalized));
        }
        return cleanPath(baseDir + "/" + normalized);
    }

    function stripExtension(path) {
        return path.replace(/\.[^/.]+$/, "");
    }

    function basenameNoExt(path) {
        var n = normalizePath(path);
        n = n.replace(/^.*\//, "");
        return stripExtension(n);
    }

    function basename(path) {
        return normalizePath(path).replace(/^.*\//, "");
    }

    // Mirror mvtk/audio/music_sync.lua -> sanitize_track_id so the track id
    // reported at export matches what Project > Sync Music will generate.
    function sanitizeTrackId(filename) {
        var id = basenameNoExt(filename).toLowerCase();
        id = id.replace(/[\s\-]+/g, "_");
        id = id.replace(/[^a-z0-9_]/g, "");
        id = id.replace(/_+/g, "_");
        id = id.replace(/^_+/, "").replace(/_+$/, "");
        return id;
    }

    // A map property value as a plain string across Tiled versions: file
    // properties come back as FilePath objects ({ url }), enum properties as
    // PropertyValue objects ({ value }), everything else as primitives.
    function propertyToString(value) {
        if (value === undefined || value === null) return "";
        if (typeof value === "string") return value;
        var inner = (value.url !== undefined) ? value.url
            : (value.value !== undefined) ? value.value
            : value;
        var s = String(inner || "");
        if (s.indexOf("file:///") === 0) {
            s = s.slice(8);
            // file:///V:/x -> V:/x already correct; file:///home/x needs its
            // leading slash restored.
            if (s.indexOf(":") !== 1) s = "/" + s;
        } else if (s.indexOf("file://") === 0) {
            s = s.slice(7);
        }
        try { s = decodeURIComponent(s); } catch (e) { /* keep raw */ }
        return normalizePath(s);
    }

    function safeMapProperty(map, name) {
        try {
            if (map && typeof map.property === "function") return map.property(name);
        } catch (e) { /* missing property API */ }
        return null;
    }

    // Feature-detect the file APIs across Tiled versions. The static `File`
    // helpers and `BinaryFile` both landed in Tiled 1.8; older builds have
    // neither, in which case we fall back to TextFile for .tsx only.
    var HAS_FILE = (typeof File !== "undefined");
    var HAS_BINARY = (typeof BinaryFile !== "undefined");

    // Adler-32 with the modulo deferred to every 5552 bytes (zlib's NMAX: the longest
    // run for which b cannot exceed 2^32). Results are identical to the per-byte form
    // the Lua side uses; only the speed differs (~10x in Tiled 1.12).
    function adlerBytes(bytes) {
        var a = 1, b = 0, n = bytes.length, i = 0;
        while (i < n) {
            var end = Math.min(i + 5552, n);
            for (; i < end; i++) { a += bytes[i]; b += a; }
            a %= 65521; b %= 65521;
        }
        return n + ":" + a + ":" + b;
    }

    // Fingerprints computed during one export action. A world run shares one memo
    // across all rooms; every write helper forgets the paths it touches.
    var fingerprintMemo = null;
    var fingerprintStats = { files: 0, bytes: 0, ms: 0, hits: 0 };
    function beginFingerprintMemo() {
        if (fingerprintMemo) return false;
        fingerprintMemo = { binary: {}, text: {} };
        fingerprintStats = { files: 0, bytes: 0, ms: 0, hits: 0 };
        return true;
    }
    function endFingerprintMemo(owned) { if (owned) fingerprintMemo = null; }
    function forgetFingerprint(path) {
        if (!fingerprintMemo || !path) return;
        var key = pathKey(path);
        delete fingerprintMemo.binary[key];
        delete fingerprintMemo.text[key];
    }
    function fileFingerprint(path, bypassMemo) {
        var key = pathKey(path);
        if (!bypassMemo && fingerprintMemo && fingerprintMemo.binary[key] !== undefined) {
            fingerprintStats.hits++;
            return fingerprintMemo.binary[key];
        }
        var started = Date.now();
        var file = new BinaryFile(path, BinaryFile.ReadOnly);
        var bytes = new Uint8Array(file.readAll()); file.close();
        var signature = adlerBytes(bytes);
        fingerprintStats.files++;
        fingerprintStats.bytes += bytes.length;
        fingerprintStats.ms += Date.now() - started;
        if (fingerprintMemo) fingerprintMemo.binary[key] = signature;
        return signature;
    }
    function textFingerprint(path) {
        var key = pathKey(path);
        if (fingerprintMemo && fingerprintMemo.text[key] !== undefined) {
            fingerprintStats.hits++;
            return fingerprintMemo.text[key];
        }
        var started = Date.now(), text = readTextFile(path);
        var signature = MVTKRelationships.fingerprint(text);
        var result = { signature: signature, text: text };
        fingerprintStats.files++;
        fingerprintStats.bytes += Number(signature.split(":")[0]);
        fingerprintStats.ms += Date.now() - started;
        if (fingerprintMemo) fingerprintMemo.text[key] = result;
        return result;
    }

    function fileExists(path) {
        if (HAS_FILE && typeof File.exists === "function") {
            try { return File.exists(path); } catch (e) { /* fall through */ }
        }
        return fileReadable(path);
    }

    function fileSize(path) {
        // Best-effort: read back via BinaryFile to confirm a non-empty write.
        if (HAS_BINARY) {
            try {
                var f = new BinaryFile(path, BinaryFile.ReadOnly);
                var n = f.size;
                f.close();
                return n;
            } catch (e) { return -1; }
        }
        return fileExists(path) ? 1 : -1;
    }

    // Compare complete binary payloads before deciding whether an existing
    // project music file is the same asset or a basename collision. Tiled
    // 1.12 exposes Base64 alongside BinaryFile; the size check avoids reading
    // the second file when the answer is already known.
    function binaryFilesEqual(a, b) {
        if (!HAS_BINARY || !fileExists(a) || !fileExists(b)) return false;
        if (Number(fileSize(a)) !== Number(fileSize(b))) return false;
        try {
            var aFile = new BinaryFile(a, BinaryFile.ReadOnly);
            var aData = aFile.readAll();
            aFile.close();
            var bFile = new BinaryFile(b, BinaryFile.ReadOnly);
            var bData = bFile.readAll();
            bFile.close();
            if (typeof Base64 !== "undefined" &&
                typeof Base64.encode === "function") {
                return String(Base64.encode(aData)) === String(Base64.encode(bData));
            }
            // The fallback is only for older script engines. Supported Tiled
            // builds take the Base64 branch above.
            var aBytes = new Uint8Array(aData), bBytes = new Uint8Array(bData);
            if (aBytes.length !== bBytes.length) return false;
            for (var i = 0; i < aBytes.length; i++) if (aBytes[i] !== bBytes[i]) return false;
            return true;
        } catch (e) {
            // Treat an unreadable comparison conservatively as a collision;
            // the project copy is never overwritten in that case.
            return false;
        }
    }

    // Make sure a directory (and parents) exists before writing into it.
    function ensureDir(dir) {
        if (HAS_FILE && typeof File.makePath === "function") {
            try { File.makePath(dir); } catch (e) { /* best effort */ }
        }
    }

    // Windows can refuse to replace a file that another program (an antivirus
    // scan or the search indexer) opened just after the previous write: Tiled's
    // safe-write commit renames over the target and throws "Access is denied".
    // The world export journal is rewritten many times per export, so retry
    // briefly before reporting the failure. Each attempt writes the whole file.
    var WRITE_RETRY_DELAYS_MS = [20, 50, 100, 200, 400];
    function waitMs(ms) {
        var end = Date.now() + ms;
        while (Date.now() < end) { /* Tiled's script API has no sleep */ }
    }
    function writeWithRetry(write) {
        for (var attempt = 0; ; attempt++) {
            try { return write(); } catch (e) {
                if (attempt >= WRITE_RETRY_DELAYS_MS.length) throw e;
                waitMs(WRITE_RETRY_DELAYS_MS[attempt]);
            }
        }
    }

    // Copy one file, overwriting the destination so the latest art/tsx wins.
    // Returns null on success, or an error string describing what failed.
    function copyOne(src, dst, isBinary) {
        if (_g.__mvtkWorldContext) _g.__mvtkWorldContext.beforeWrite(dst);
        if (!src) return "no source path";
        if (!fileExists(src)) return "source not found: " + src;
        if (pathKey(src) === pathKey(dst)) return null; // already in place
        // Avoid rewriting a shared tilesheet for every map in a world. Tiled
        // and Defold may be reading it while the next room is exported.
        if (binaryFilesEqual(src, dst)) return null;

        forgetFingerprint(dst);
        ensureDir(dirname(dst));

        // Preferred: binary-safe read/write (overwrites). Works for PNG + tsx.
        if (HAS_BINARY) {
            try {
                var inF = new BinaryFile(src, BinaryFile.ReadOnly);
                var data = inF.readAll();
                inF.close();
                writeWithRetry(function () {
                    var outF = new BinaryFile(dst, BinaryFile.WriteOnly);
                    outF.write(data);
                    // Tiled 1.8+ commit() writes to disk AND closes the file, so a
                    // following close() throws "Access to BinaryFile object that was
                    // already closed". Only close() ourselves on older Tiled that
                    // lacks commit(), where close() is what flushes the write.
                    if (typeof outF.commit === "function") {
                        outF.commit();
                    } else {
                        outF.close();
                    }
                });
            } catch (e) {
                return "write failed (" + e + ")";
            }
        } else if (HAS_FILE && typeof File.copy === "function") {
            // File.copy refuses to overwrite, so clear the target first.
            try {
                if (fileExists(dst) && typeof File.remove === "function") File.remove(dst);
                if (!File.copy(src, dst)) return "File.copy returned false";
            } catch (e) {
                return "File.copy failed (" + e + ")";
            }
        } else if (!isBinary) {
            // Last resort for .tsx (text) on ancient Tiled with no binary API.
            try {
                writeTextFile(dst, readTextFile(src));
            } catch (e) {
                return "text copy failed (" + e + ")";
            }
        } else {
            return "no binary file API (needs Tiled 1.8+) to copy image";
        }

        // Verify something actually landed.
        if (!fileExists(dst)) return "destination missing after copy";
        if (fileSize(dst) === 0) return "destination is empty after copy";
        return null;
    }

    // Copy tracking is destination-based so equally named files in different
    // output folders do not alias each other. A second, different source aimed
    // at the same destination is a hard failure instead of silently replacing
    // the first asset.
    function copyTracked(src, dst, isBinary, tracker) {
        if (_g.__mvtkWorldContext) _g.__mvtkWorldContext.asset(src, dst);
        var sourceKey = pathKey(src);
        var destinationKey = pathKey(dst);
        var key = "dst:" + destinationKey;
        var previous = tracker.byDestination[key];
        if (previous) {
            if (previous.sourceKey !== sourceKey) {
                return "destination collision: " + dst + " is already assigned from " + previous.source;
            }
            return previous.error;
        }

        var world = _g.__mvtkWorldContext;
        if (world && world.localized[key] && world.localized[key].sourceKey === sourceKey) {
            tracker.byDestination[key] = {
                source: normalizePath(src), sourceKey: sourceKey,
                destination: normalizePath(dst), destinationKey: destinationKey, error: null
            };
            return null;
        }

        var backupError = prepareTrackedDestination(dst, tracker);
        if (backupError) {
            tracker.byDestination[key] = {
                source: normalizePath(src),
                sourceKey: sourceKey,
                destination: normalizePath(dst),
                destinationKey: destinationKey,
                error: backupError
            };
            return backupError;
        }

        var error = copyOne(src, dst, isBinary);
        if (!error) error = recordSourceCopy(src, dst, tracker);
        tracker.byDestination[key] = {
            source: normalizePath(src),
            sourceKey: sourceKey,
            destination: normalizePath(dst),
            destinationKey: destinationKey,
            error: error
        };
        return error;
    }

    // Reset may remove a copy only while its external original is available.
    // The receipt also detects edits made accidentally to a project copy.
    function recordSourceCopy(src, dst, tracker, stagedPath) {
        var receipt = dst + ".mvtk-source";
        var error = prepareTrackedDestination(receipt, tracker);
        if (error) return error;
        try {
            writeTextFile(receipt, canonicalAuthoringPath(src) + "\n" + fileFingerprint(stagedPath || dst) + "\n");
        } catch (e) { return "could not record external source: " + e; }
        return null;
    }

    function prepareTrackedDestination(dst, tracker) {
        var destinationKey = pathKey(dst);
        var key = "dst:" + destinationKey;
        if (tracker.transactionByDestination[key]) return null;

        var backupPath = dst + ".mvtk_asset_backup";
        removeFileIfPresent(backupPath);
        var hadOriginal = fileExists(dst);
        if (hadOriginal) {
            var backupError = copyOne(dst, backupPath, true);
            if (backupError) {
                removeFileIfPresent(backupPath);
                return "could not back up existing destination (" + backupError + ")";
            }
        }
        var entry = {
            destination: dst,
            destinationKey: destinationKey,
            backupPath: backupPath,
            hadOriginal: hadOriginal
        };
        tracker.transactionByDestination[key] = entry;
        tracker.transaction.push(entry);
        return null;
    }

    function rollbackTrackedDestinations(tracker) {
        var errors = [];
        for (var i = tracker.transaction.length - 1; i >= 0; i--) {
            var entry = tracker.transaction[i];
            var restored = true;
            if (entry.hadOriginal && fileExists(entry.backupPath)) {
                var restoreError = moveFileOverwrite(entry.backupPath, entry.destination);
                if (restoreError) {
                    errors.push(entry.destination + ": " + restoreError);
                    restored = false;
                }
            } else if (!entry.hadOriginal) {
                removeFileIfPresent(entry.destination);
            }
            // Keep a recovery copy on disk if automatic restoration failed.
            if (restored) removeFileIfPresent(entry.backupPath);
        }
        return errors;
    }

    function commitTrackedDestinations(tracker) {
        for (var i = 0; i < tracker.transaction.length; i++) {
            removeFileIfPresent(tracker.transaction[i].backupPath);
        }
    }

    // A failed room never makes its partially localized assets reusable.
    function promoteLocalizedAssets(assets) {
        var world = _g.__mvtkWorldContext, tracker = assets && assets.transaction;
        if (!world || !tracker) return;
        [tracker.byDestination, tracker.localizedTsx || {}].forEach(function(entries) {
            Object.keys(entries).forEach(function(key) {
                if (!entries[key].error) world.localized[key] = entries[key];
            });
        });
    }

    function wasCopiedSuccessfully(tracker, src, dst) {
        var entry = tracker.byDestination["dst:" + pathKey(dst)];
        return !!entry && !entry.error && entry.sourceKey === pathKey(src);
    }

    function decodeXmlAttribute(value) {
        return String(value || "")
            .replace(/&#x([0-9a-f]+);/gi, function (_, n) {
                return String.fromCharCode(parseInt(n, 16));
            })
            .replace(/&#([0-9]+);/g, function (_, n) {
                return String.fromCharCode(parseInt(n, 10));
            })
            .replace(/&quot;/g, '"')
            .replace(/&apos;/g, "'")
            .replace(/&lt;/g, "<")
            .replace(/&gt;/g, ">")
            .replace(/&amp;/g, "&");
    }

    function encodeXmlAttribute(value) {
        return String(value || "")
            .replace(/&/g, "&amp;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&apos;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;");
    }

    // A copied external TSX still contains image paths relative to its original
    // location (and can contain an absolute path). Rewrite only image sources
    // whose exact source-to-destination copy succeeded during this export. This
    // prevents a failed copy from being hidden by an older same-named file.
    function buildLocalizedTsxText(originalTsxPath, localImageDir, relativePrefix, tracker) {
        if (!originalTsxPath || !fileExists(originalTsxPath)) {
            return { text: "", count: 0, error: "source TSX is missing" };
        }
        var text;
        try {
            text = readTextFile(originalTsxPath);
        } catch (e) {
            return { text: "", count: 0, error: "could not read source TSX (" + e + ")" };
        }

        var count = 0;
        var unresolved = [];
        text = text.replace(/(<image\b[^>]*\bsource=)(["'])(.*?)\2/g,
            function (full, prefix, quote, encodedSource) {
                var source = decodeXmlAttribute(encodedSource);
                var sourcePath = resolvePath(dirname(originalTsxPath), source);
                var imageName = basename(sourcePath);
                var localImage = localImageDir + "/" + imageName;
                if (!imageName || !wasCopiedSuccessfully(tracker, sourcePath, localImage)) {
                    unresolved.push(source || "(empty image source)");
                    return full;
                }
                var relinked = relativePrefix + imageName;
                if (source !== relinked) count++;
                return prefix + quote + encodeXmlAttribute(relinked) + quote;
            });

        if (unresolved.length > 0) {
            return {
                text: "",
                count: 0,
                error: "could not localize image source(s): " + unresolved.join(", ")
            };
        }
        return { text: text, count: count, error: "" };
    }

    // Publish only already-localized TSX text. The raw external TSX is never
    // copied over a canonical project file, so a later image/relink failure
    // cannot recreate the broken external-path state this exporter is healing.
    function publishLocalizedTsx(originalTsxPath, localTsxPath, localImageDir, relativePrefix, tracker) {
        var world = _g.__mvtkWorldContext;
        if (world) world.asset(originalTsxPath, localTsxPath);
        var key = "tsx:" + pathKey(localTsxPath), sourceKey = pathKey(originalTsxPath);
        if (world && world.localized[key] && world.localized[key].sourceKey === sourceKey) return null;
        var localized = buildLocalizedTsxText(
            originalTsxPath, localImageDir, relativePrefix, tracker
        );
        if (localized.error) return localized.error;
        try {
            var existing = fileExists(localTsxPath) ? readTextFile(localTsxPath) : null;
            if (existing !== localized.text) {
                var backupError = prepareTrackedDestination(localTsxPath, tracker);
                if (backupError) return backupError;
                writeTextFile(localTsxPath, localized.text);
                if (!fileExists(localTsxPath) || readTextFile(localTsxPath) !== localized.text) {
                    return "localized TSX verification failed";
                }
            }
        } catch (e) {
            return "could not publish localized TSX (" + e + ")";
        }
        var error = recordSourceCopy(originalTsxPath, localTsxPath, tracker);
        if (!error) {
            if (!tracker.localizedTsx) tracker.localizedTsx = {};
            tracker.localizedTsx[key] = { sourceKey: sourceKey, error: null };
        }
        return error;
    }

    // Tiled's Lua exporter records the path of the tileset object currently
    // loaded in memory. If that object came from outside the project, keep the
    // generated Lua portable by pointing it at the TSX copy made above.
    function relinkExportedLuaTilesetPaths(luaPath, assets) {
        var text;
        try {
            text = readTextFile(luaPath);
        } catch (e) {
            return { count: 0, error: "could not read Lua export (" + e + ")" };
        }

        var count = 0;
        var unresolved = [];
        text = text.replace(/filename\s*=\s*"([^"]+\.tsx)"/g, function (full, source) {
            var tsxName = basename(source);
            var sourcePath = resolvePath(dirname(luaPath), source);
            var relink = null;
            var candidates = (assets && assets.tsxRelinks) || [];
            for (var i = 0; i < candidates.length; i++) {
                if (candidates[i].success && candidates[i].sourceKey === pathKey(sourcePath)) {
                    relink = candidates[i];
                    break;
                }
            }
            if (!relink) {
                unresolved.push(source);
                return full;
            }
            var relinked = "../tilesets/" + basename(relink.localPath || tsxName);
            if (normalizePath(source) === relinked) return full;
            count++;
            return full.replace(source, relinked);
        });

        if (count > 0) {
            try {
                writeTextFile(luaPath, text);
            } catch (e2) {
                return { count: 0, error: "could not relink Lua tilesets (" + e2 + ")" };
            }
        }
        if (unresolved.length > 0) {
            return {
                count: count,
                error: "no successful project-local TSX copy for: " + unresolved.join(", ")
            };
        }
        return { count: count, error: "" };
    }

    function imageLayerSource(layer, map) {
        if (!layer || !layer.isImageLayer) return "";
        // imageFileName is Tiled 1.12's plain-string API. imageSource is a QUrl
        // retained as a compatibility fallback for other supported builds.
        var source = propertyToString(layer.imageFileName || layer.imageSource || "");
        if (!source) return "";
        if (isAbsolutePath(source)) return cleanPath(source);
        var mapFileName = propertyToString(map && map.fileName);
        return resolvePath(dirname(mapFileName), source);
    }

    // Return each distinct image-layer source, including image layers nested in
    // groups. Tiled exposes imageSource as an absolute path in current builds,
    // while the fallback resolution keeps older versions deterministic.
    function collectImageLayerSources(map) {
        var result = [];
        var seen = {};
        try {
            eachLayer(map, function (layer) {
                var source = imageLayerSource(layer, map);
                if (!source) return;
                var key = pathKey(source);
                if (seen[key]) return;
                seen[key] = true;
                result.push({
                    source: source,
                    sourceKey: key,
                    layerName: String(layer.name || "(unnamed image layer)")
                });
            });
        } catch (e) {
            // A supported Tiled build always exposes layerCount/layerAt. Let the
            // exported-Lua relink fail closed if a future API shape changes.
            tiled.log("[MVTK] Could not inspect image layers during asset localization: " + e);
        }
        return result;
    }

    // Locate Lua table ranges while ignoring braces inside strings/comments.
    // This lets image paths be changed only in tables explicitly identified as
    // image layers, without touching the `image` fields in tileset tables.
    function luaTableRanges(text) {
        var stack = [];
        var ranges = [];
        var quote = "";
        var escaped = false;
        var lineComment = false;
        for (var i = 0; i < text.length; i++) {
            var c = text.charAt(i);
            var next = text.charAt(i + 1);
            if (lineComment) {
                if (c === "\n") lineComment = false;
                continue;
            }
            if (quote) {
                if (escaped) escaped = false;
                else if (c === "\\") escaped = true;
                else if (c === quote) quote = "";
                continue;
            }
            if (c === "-" && next === "-") {
                lineComment = true;
                i++;
            } else if (c === "\"" || c === "'") {
                quote = c;
            } else if (c === "{") {
                stack.push(i);
            } else if (c === "}" && stack.length > 0) {
                ranges.push({ start: stack.pop(), end: i + 1 });
            }
        }
        return ranges;
    }

    function successfulRelinkForSource(candidates, sourcePath) {
        var sourceKey = pathKey(sourcePath);
        for (var i = 0; i < (candidates || []).length; i++) {
            if (candidates[i].success && candidates[i].sourceKey === sourceKey) {
                return candidates[i];
            }
        }
        return null;
    }

    // Embedded tilesets have no `filename` entry in Tiled's Lua export. Relink
    // a direct sheet image to tilesheets/, or per-tile collection images to
    // backgrounds/. The firstgid discriminator keeps this pass out of image
    // layer tables.
    function relinkExportedLuaTilesetImagePaths(luaPath, assets) {
        var text;
        try {
            text = readTextFile(luaPath);
        } catch (e) {
            return { count: 0, error: "could not read Lua export (" + e + ")" };
        }

        var ranges = luaTableRanges(text);
        var tilesetTables = {};
        var firstGidPattern = /\bfirstgid\s*=\s*\d+/g;
        var firstGidMatch;
        while ((firstGidMatch = firstGidPattern.exec(text)) !== null) {
            var containing = null;
            for (var r = 0; r < ranges.length; r++) {
                var candidate = ranges[r];
                if (candidate.start < firstGidMatch.index && candidate.end > firstGidMatch.index &&
                    (!containing || candidate.start > containing.start)) {
                    containing = candidate;
                }
            }
            if (containing) tilesetTables[String(containing.start)] = containing;
        }

        var edits = [];
        var unresolved = [];
        for (var key in tilesetTables) {
            if (!tilesetTables.hasOwnProperty(key)) continue;
            var table = tilesetTables[key];
            var block = text.slice(table.start, table.end);
            // External TSX-backed tables are already portable through their
            // localized filename; only embedded tilesets own a direct image.
            if (/\bfilename\s*=\s*"[^"]+\.tsx"/.test(block)) continue;
            var tilesField = block.search(/\btiles\s*=\s*\{/);
            var directFields = tilesField >= 0 ? block.slice(0, tilesField) : block;
            var imageMatch = /\bimage\s*=\s*"([^"]+)"/.exec(directFields);
            if (imageMatch) {
                var source = imageMatch[1];
                var sourcePath = resolvePath(dirname(luaPath), source);
                var relink = successfulRelinkForSource(
                    (assets && assets.sheetRelinks) || [], sourcePath
                );
                if (!relink) {
                    unresolved.push(source);
                    continue;
                }
                var relinked = "../../tilesheets/" +
                    basename(relink.localPath || sourcePath);
                if (normalizePath(source) === relinked) continue;
                var sourceOffset = imageMatch.index +
                    imageMatch[0].lastIndexOf(imageMatch[1]);
                edits.push({
                    start: table.start + sourceOffset,
                    end: table.start + sourceOffset + imageMatch[1].length,
                    replacement: relinked
                });
                continue;
            }

            // Image-collection tilesets store one image in each nested tile
            // table. Every one must have a tracker-confirmed backgrounds copy.
            if (tilesField < 0) continue;
            var collectionFields = block.slice(tilesField);
            var collectionPattern = /\bimage\s*=\s*"([^"]+)"/g;
            var collectionMatch;
            while ((collectionMatch = collectionPattern.exec(collectionFields)) !== null) {
                var collectionSource = collectionMatch[1];
                var collectionSourcePath = resolvePath(
                    dirname(luaPath), collectionSource
                );
                var collectionRelink = successfulRelinkForSource(
                    (assets && assets.collectionImageRelinks) || [],
                    collectionSourcePath
                );
                if (!collectionRelink) {
                    unresolved.push(collectionSource);
                    continue;
                }
                var collectionRelinked = "../backgrounds/" +
                    basename(collectionRelink.localPath || collectionSourcePath);
                if (normalizePath(collectionSource) === collectionRelinked) continue;
                var collectionSourceOffset = tilesField + collectionMatch.index +
                    collectionMatch[0].lastIndexOf(collectionMatch[1]);
                edits.push({
                    start: table.start + collectionSourceOffset,
                    end: table.start + collectionSourceOffset +
                        collectionMatch[1].length,
                    replacement: collectionRelinked
                });
            }
        }

        edits.sort(function (a, b) { return b.start - a.start; });
        for (var e = 0; e < edits.length; e++) {
            text = text.slice(0, edits[e].start) + edits[e].replacement +
                text.slice(edits[e].end);
        }
        if (edits.length > 0) {
            try { writeTextFile(luaPath, text); }
            catch (e2) {
                return { count: 0, error: "could not relink Lua tileset images (" + e2 + ")" };
            }
        }
        if (unresolved.length > 0) {
            return {
                count: edits.length,
                error: "no successful project-local tileset image copy for: " +
                    unresolved.join(", ")
            };
        }
        return { count: edits.length, error: "" };
    }

    // Relink only image-layer tables in the Lua export. Tileset `image` keys
    // are handled separately above and point to tilesheets/, never backgrounds/.
    function relinkExportedLuaImageLayerPaths(luaPath, assets) {
        var text;
        try {
            text = readTextFile(luaPath);
        } catch (e) {
            return { count: 0, error: "could not read Lua export (" + e + ")" };
        }

        var ranges = luaTableRanges(text);
        var imageTables = {};
        var typePattern = /\btype\s*=\s*"imagelayer"/g;
        var typeMatch;
        while ((typeMatch = typePattern.exec(text)) !== null) {
            var containing = null;
            for (var r = 0; r < ranges.length; r++) {
                var candidate = ranges[r];
                if (candidate.start < typeMatch.index && candidate.end > typeMatch.index &&
                    (!containing || candidate.start > containing.start)) {
                    containing = candidate;
                }
            }
            if (containing) imageTables[String(containing.start)] = containing;
        }

        var edits = [];
        var unresolved = [];
        for (var key in imageTables) {
            if (!imageTables.hasOwnProperty(key)) continue;
            var table = imageTables[key];
            var block = text.slice(table.start, table.end);
            var imageMatch = /\bimage\s*=\s*"([^"]+)"/.exec(block);
            if (!imageMatch) continue;
            var source = imageMatch[1];
            var sourcePath = resolvePath(dirname(luaPath), source);
            var relink = successfulRelinkForSource(
                (assets && assets.imageRelinks) || [], sourcePath
            );
            if (!relink) {
                unresolved.push(source);
                continue;
            }
            var relinked = "../backgrounds/" + basename(relink.localPath || sourcePath);
            if (normalizePath(source) === relinked) continue;
            var sourceOffset = imageMatch.index + imageMatch[0].lastIndexOf(imageMatch[1]);
            edits.push({
                start: table.start + sourceOffset,
                end: table.start + sourceOffset + imageMatch[1].length,
                replacement: relinked
            });
        }

        edits.sort(function (a, b) { return b.start - a.start; });
        for (var e = 0; e < edits.length; e++) {
            text = text.slice(0, edits[e].start) + edits[e].replacement +
                text.slice(edits[e].end);
        }
        if (edits.length > 0) {
            try {
                writeTextFile(luaPath, text);
            } catch (e2) {
                return { count: 0, error: "could not relink Lua image layers (" + e2 + ")" };
            }
        }
        if (unresolved.length > 0) {
            return {
                count: edits.length,
                error: "no successful project-local image copy for: " + unresolved.join(", ")
            };
        }
        return { count: edits.length, error: "" };
    }

    // Tiled's Lua exporter preserves the map property spelling it read from
    // the authoring TMX. When music localization selected a project copy,
    // rewrite only that one map-level property in the staged Lua export.
    function relinkExportedLuaMusicPath(luaPath, assets) {
        var music = assets && assets.music;
        if (!music || !music.relinked) return { count: 0, error: "" };

        var text;
        try {
            text = readTextFile(luaPath);
        } catch (e) {
            return { count: 0, error: "could not read Lua export (" + e + ")" };
        }

        var propertiesMatch = /\bproperties\s*=\s*\{/.exec(text);
        if (!propertiesMatch) {
            return { count: 0, error: "map properties table is missing" };
        }
        var openIndex = text.indexOf("{", propertiesMatch.index);
        var closeIndex = findMatchingBrace(text, openIndex);
        if (closeIndex < 0) {
            return { count: 0, error: "map properties table is malformed" };
        }

        var escapedName = String(music.propertyName || "")
            .replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        var propertyPattern = new RegExp(
            '(\\["' + escapedName + '"\\]\\s*=\\s*)"((?:\\\\.|[^"])*)"'
        );
        var propertiesText = text.slice(openIndex, closeIndex + 1);
        var found = false;
        var changed = false;
        propertiesText = propertiesText.replace(
            propertyPattern,
            function (full, prefix, currentValue) {
                found = true;
                if (normalizePath(currentValue) === music.relativePath) return full;
                changed = true;
                return prefix + '"' + music.relativePath + '"';
            }
        );
        if (!found) {
            return {
                count: 0,
                error: "localized room music property '" + music.propertyName + "' is missing"
            };
        }
        if (changed) {
            text = text.slice(0, openIndex) + propertiesText +
                text.slice(closeIndex + 1);
            try {
                writeTextFile(luaPath, text);
            } catch (e2) {
                return { count: 0, error: "could not relink Lua room music (" + e2 + ")" };
            }
        }
        return { count: changed ? 1 : 0, error: "" };
    }

    // The image-file path for one tile in an image-collection tileset, across
    // Tiled API versions. `imageFileName` is the documented property; some
    // builds only expose `image` as a path-ish string.
    function tileImageFileName(tile) {
        if (!tile) return "";
        if (typeof tile.imageFileName === "string" && tile.imageFileName) return tile.imageFileName;
        if (typeof tile.image === "string" && tile.image) return tile.image;
        return "";
    }

    function tilesetImageFileName(ts) {
        if (!ts) return "";
        if (typeof ts.imageFileName === "string" && ts.imageFileName) return ts.imageFileName;
        if (typeof ts.image === "string" && ts.image) return ts.image;
        return "";
    }

    function preflightTilesetAssets(map, root) {
        var tilesetDir = root + "/developer/assets/tiled/tilesets";
        var sheetDir = root + "/developer/assets/tilesheets";
        var bgDir = root + "/developer/assets/tiled/backgrounds";
        var claims = {};
        var errors = [];

        function claim(src, dst, label) {
            if (!src || !fileExists(src)) {
                errors.push(label + ": source not found: " + (src || "(empty path)"));
                return;
            }
            var destinationKey = pathKey(dst);
            var sourceKey = pathKey(src);
            var key = "dst:" + destinationKey;
            if (claims[key] && claims[key].sourceKey !== sourceKey) {
                errors.push(
                    label + ": destination collision: " + dst +
                    " is also assigned from " + claims[key].source
                );
                return;
            }
            claims[key] = { source: normalizePath(src), sourceKey: sourceKey };
        }

        var sets = (map && map.tilesets) || [];
        for (var i = 0; i < sets.length; i++) {
            var ts = sets[i];
            if (!ts) continue;
            if (ts.fileName) {
                claim(
                    ts.fileName,
                    tilesetDir + "/" + basename(ts.fileName),
                    "tileset '" + (ts.name || "(unnamed)") + "'"
                );
            }
            if (ts.isCollection) {
                var tiles = ts.tiles || [];
                for (var t = 0; t < tiles.length; t++) {
                    var tileImage = tileImageFileName(tiles[t]);
                    if (tileImage) {
                        claim(tileImage, bgDir + "/" + basename(tileImage),
                            "collection image in '" + (ts.name || "(unnamed)") + "'");
                    }
                }
            } else {
                var sheetImage = tilesetImageFileName(ts);
                if (sheetImage) {
                    claim(sheetImage, sheetDir + "/" + basename(sheetImage),
                        "tilesheet image in '" + (ts.name || "(unnamed)") + "'");
                }
            }
        }
        var imageLayers = collectImageLayerSources(map);
        for (var l = 0; l < imageLayers.length; l++) {
            var layerImage = imageLayers[l];
            claim(
                layerImage.source,
                bgDir + "/" + basename(layerImage.source),
                "image layer '" + layerImage.layerName + "'"
            );
        }
        return errors;
    }

    // Copy a collection (image-of-images) tileset into the project: its external
    // .tsx plus every per-tile image. The Defold importer resolves these by
    // basename (hooks/core/tilesource.lua: resolve_source_file searches
    // developer/assets/tiled/backgrounds + tilesets + tilesheets), so flattening
    // every tile image into backgrounds/ is enough for Import Assets to find
    // them. Returns true if at least one image landed.
    function copyCollectionTileset(
        ts, tilesetDir, bgDir, tracker, copied, failed, failedTsx, tsxRelinks,
        collectionImageRelinks
    ) {
        var any = false;
        var failureStart = failed.length;

        // Images must succeed before the localized TSX is published. This
        // keeps an existing canonical TSX untouched when any nested copy fails.
        var tiles = ts.tiles || [];
        for (var t = 0; t < tiles.length; t++) {
            var src = tileImageFileName(tiles[t]);
            if (!src) continue;
            var imgName = basename(src);
            var localImage = bgDir + "/" + imgName;
            var imageRelink = {
                source: normalizePath(src),
                sourceKey: pathKey(src),
                localPath: normalizePath(localImage),
                success: false
            };
            collectionImageRelinks.push(imageRelink);
            var imgErr = copyTracked(src, localImage, true, tracker);
            if (imgErr) { failed.push(imgName + ": " + imgErr); }
            else {
                imageRelink.success = true;
                copied.push(imgName);
                any = true;
            }
        }

        if (ts.fileName) {
            var tsxName = basename(ts.fileName);
            var localTsx = tilesetDir + "/" + tsxName;
            var relink = {
                source: normalizePath(ts.fileName),
                sourceKey: pathKey(ts.fileName),
                localPath: normalizePath(localTsx),
                success: false
            };
            tsxRelinks.push(relink);
            var tsxErr = failed.length > failureStart
                ? "nested image copy failed"
                : publishLocalizedTsx(
                    ts.fileName, localTsx, bgDir, "../backgrounds/", tracker
                );
            if (tsxErr) {
                failed.push(tsxName + ": " + tsxErr);
                failedTsx[tsxName] = true;
            } else {
                relink.success = true;
                copied.push(tsxName);
                any = true;
            }
        }

        return any;
    }

    // Copy every external tileset (.tsx) and its image into the project so the
    // toolkit's Import Assets can resolve them without manual file shuffling.
    //   * .tsx        -> developer/assets/tiled/tilesets/
    //   * sheet image -> developer/assets/tilesheets/
    //   * collection per-tile images -> developer/assets/tiled/backgrounds/
    // Embedded tilesets (no .tsx) still get their image copied. Collection
    // (image-collection) tilesets get every per-tile image copied so the
    // importer can resolve them by basename.
    // Returns { copied: [names], failed: [ "name: reason" ], skippedCollections: [names] }.
    function copyTilesetAssets(map, root, relationshipRecords) {
        var tilesetDir = root + "/developer/assets/tiled/tilesets";
        var sheetDir = root + "/developer/assets/tilesheets";
        var bgDir = root + "/developer/assets/tiled/backgrounds";
        var copied = [];
        var failed = preflightTilesetAssets(map, root);
        var skippedCollections = [];
        var tracker = {
            byDestination: {},
            transaction: [],
            transactionByDestination: {}
        };
        var failedTsx = {};
        var tsxRelinks = [];
        var sheetRelinks = [];
        var collectionImageRelinks = [];
        var imageRelinks = [];
        var music = collectRoomMusic(map, root);
        var copiedMusic = [];
        var enemyArt = { objects: [], sourceFiles: [], localFiles: [], copied: [], warnings: [] };

        // Collision/missing-source preflight is intentionally write-free.
        if (failed.length > 0) {
            return {
                copied: copied,
                failed: failed,
                skippedCollections: skippedCollections,
                failedTsx: failedTsx,
                tsxRelinks: tsxRelinks,
                sheetRelinks: sheetRelinks,
                collectionImageRelinks: collectionImageRelinks,
                imageRelinks: imageRelinks,
                music: music,
                copiedMusic: copiedMusic
            };
        }

        ensureDir(tilesetDir);
        ensureDir(sheetDir);
        ensureDir(bgDir);
        var sets = map.tilesets || [];

        for (var i = 0; i < sets.length; i++) {
            var ts = sets[i];
            if (!ts) continue;
            if (ts.isCollection) {
                var copiedAny = copyCollectionTileset(
                    ts, tilesetDir, bgDir, tracker, copied, failed, failedTsx,
                    tsxRelinks, collectionImageRelinks
                );
                if (!copiedAny) {
                    tiled.log("[MVTK] Collection tileset '" + ts.name + "' had no copyable per-tile images");
                    skippedCollections.push(ts.name || "(unnamed collection tileset)");
                } else {
                    tiled.log("[MVTK] Copied collection tileset '" + ts.name + "' per-tile images");
                }
                continue;
            }

            var failureStart = failed.length;
            var tsxRelink = null;

            // Publish the localized TSX only after its sheet image succeeds.
            var sheetImage = tilesetImageFileName(ts);
            var sheetRelink = null;
            if (sheetImage) {
                var imgName = basename(sheetImage);
                sheetRelink = {
                    source: normalizePath(sheetImage),
                    sourceKey: pathKey(sheetImage),
                    localPath: normalizePath(sheetDir + "/" + imgName),
                    success: false
                };
                sheetRelinks.push(sheetRelink);
                var imgErr = copyTracked(sheetImage, sheetDir + "/" + imgName, true, tracker);
                if (imgErr) { failed.push(imgName + ": " + imgErr); }
                else {
                    sheetRelink.success = true;
                    copied.push(imgName);
                }
            }

            if (ts.fileName) {
                var tsxName = basename(ts.fileName);
                var localTsx = tilesetDir + "/" + tsxName;
                tsxRelink = {
                    source: normalizePath(ts.fileName),
                    sourceKey: pathKey(ts.fileName),
                    localPath: normalizePath(localTsx),
                    success: false
                };
                tsxRelinks.push(tsxRelink);
                var tsxErr = failed.length > failureStart
                    ? "nested image copy failed"
                    : publishLocalizedTsx(
                        ts.fileName, localTsx, sheetDir, "../../tilesheets/", tracker
                    );
                if (tsxErr) {
                    failed.push(tsxName + ": " + tsxErr);
                    failedTsx[tsxName] = true;
                } else {
                    tsxRelink.success = true;
                    copied.push(tsxName);
                }
            }
        }

        // Image layers are localized into backgrounds/ regardless of whether
        // the source map itself is inside or outside the project. They share
        // the tileset transaction, so any later export failure restores every
        // destination together.
        var imageLayers = collectImageLayerSources(map);
        for (var l = 0; l < imageLayers.length; l++) {
            var layerImage = imageLayers[l];
            var imageName = basename(layerImage.source);
            var localImage = bgDir + "/" + imageName;
            var imageRelink = {
                source: normalizePath(layerImage.source),
                sourceKey: layerImage.sourceKey,
                localPath: normalizePath(localImage),
                success: false
            };
            imageRelinks.push(imageRelink);
            var layerImageErr = copyTracked(
                layerImage.source, localImage, true, tracker
            );
            if (layerImageErr) {
                failed.push(imageName + ": " + layerImageErr);
            } else {
                imageRelink.success = true;
                copied.push(imageName);
            }
        }

        // Music participates in the same transaction as tilesets and image
        // layers. A later Lua/TMX/publication failure therefore removes a new
        // track copy along with every other newly localized asset.
        if (failed.length === 0) {
            var musicLocalization = localizeRoomMusic(map, root, tracker);
            music = musicLocalization.music;
            copiedMusic = musicLocalization.copied;
            for (var musicFailure = 0;
                musicFailure < musicLocalization.failed.length; musicFailure++) {
                failed.push(musicLocalization.failed[musicFailure]);
            }
        }
        if (failed.length === 0) {
            var enemyLocalization = localizeEnemyArt(map, root, tracker, relationshipRecords);
            enemyArt = enemyLocalization.art;
            failed = failed.concat(enemyLocalization.failed);
        }
        if (failed.length > 0) {
            var rollbackErrors = rollbackTrackedDestinations(tracker);
            for (var r = 0; r < rollbackErrors.length; r++) {
                failed.push("rollback failed: " + rollbackErrors[r]);
            }
            copied = [];
            copiedMusic = [];
            if (music && music.copied) {
                music.copied = false;
                music.relinked = false;
            }
            for (var relinkIndex = 0; relinkIndex < tsxRelinks.length; relinkIndex++) {
                tsxRelinks[relinkIndex].success = false;
            }
            for (var imageRelinkIndex = 0;
                imageRelinkIndex < imageRelinks.length; imageRelinkIndex++) {
                imageRelinks[imageRelinkIndex].success = false;
            }
            for (var sheetRelinkIndex = 0;
                sheetRelinkIndex < sheetRelinks.length; sheetRelinkIndex++) {
                sheetRelinks[sheetRelinkIndex].success = false;
            }
            for (var collectionRelinkIndex = 0;
                collectionRelinkIndex < collectionImageRelinks.length;
                collectionRelinkIndex++) {
                collectionImageRelinks[collectionRelinkIndex].success = false;
            }
        }

        return {
            copied: copied,
            failed: failed,
            skippedCollections: skippedCollections,
            failedTsx: failedTsx,
            tsxRelinks: tsxRelinks,
            sheetRelinks: sheetRelinks,
            collectionImageRelinks: collectionImageRelinks,
            imageRelinks: imageRelinks,
            music: music,
            copiedMusic: copiedMusic,
            enemyArt: enemyArt,
            transaction: failed.length > 0 ? null : tracker
        };
    }

    function rollbackTilesetAssets(assets) {
        if (!assets || !assets.transaction) return [];
        var errors = rollbackTrackedDestinations(assets.transaction);
        assets.transaction = null;
        return errors;
    }

    function commitTilesetAssets(assets) {
        if (!assets || !assets.transaction) return;
        commitTrackedDestinations(assets.transaction);
        assets.transaction = null;
    }

    function appendAssetRollbackErrors(message, assets) {
        var errors = rollbackTilesetAssets(assets);
        if (errors.length === 0) return message;
        return message + "\n\nAutomatic asset rollback also failed; recovery backups were kept:\n  " +
            errors.join("\n  ");
    }

    function dirname(path) {
        var n = normalizePath(path);
        return n.replace(/\/[^/]*$/, "");
    }

    function fileReadable(path) {
        // Best-effort existence check: opening a missing file throws.
        try {
            var f = new TextFile(path, TextFile.ReadOnly);
            f.close();
            return true;
        } catch (e) {
            return false;
        }
    }

    function readOverrideFile(overrideFile) {
        // First non-blank, non-comment line is treated as an absolute repo-root override.
        if (!overrideFile) return "";
        try {
            var text = readTextFile(overrideFile);
            var lines = text.split(/\r?\n/);
            for (var i = 0; i < lines.length; i++) {
                var line = lines[i].replace(/^\s+|\s+$/g, "");
                if (!line || line.charAt(0) === "#") continue;
                return normalizePath(line).replace(/\/+$/, "");
            }
        } catch (e) { /* missing or unreadable: ignore */ }
        return "";
    }

    function readOverrideFrom(root) {
        // export_path.txt lives at <root>/tiled/extensions/.
        if (!root) return "";
        return readOverrideFile(root + "/tiled/extensions/export_path.txt");
    }

    function readOverrideNextToExtension() {
        var scriptPath = normalizePath(typeof __filename === "string" ? __filename : "");
        if (!scriptPath) return "";
        return readOverrideFile(dirname(scriptPath) + "/export_path.txt");
    }

    function looksLikeRoot(root) {
        if (!root) return false;
        return fileReadable(root + "/game.project") ||
               fileReadable(root + "/tiled/extensions/export_lua_and_defold.js");
    }

    // Collect candidate toolkit-root folders from every signal we have, most
    // reliable first. We deliberately do NOT rely on __filename alone: some
    // Tiled builds do not expose it to the action callback, which produced the
    // old "Could not detect project root" failures.
    function candidateRoots() {
        var roots = [];
        function add(r) {
            if (r) roots.push(normalizePath(r).replace(/\/+$/, ""));
        }

        // 1. The active map's own path. Rooms are always saved under
        //    developer/assets/tiled/maps, so this pins the root directly and
        //    needs neither __filename nor the project file.
        try {
            var asset = tiled.activeAsset;
            if (asset && asset.fileName) {
                var mapPath = normalizePath(asset.fileName);
                var mk = mapPath.indexOf("/developer/assets/tiled/maps/");
                if (mk >= 0) add(mapPath.slice(0, mk));
            }
        } catch (e) { /* ignore */ }

        // 2. The open Tiled project file. MVTK.tiled-project sits at the root,
        //    but also handle it being nested under /tiled or the assets path.
        var projectPath = normalizePath(tiled.projectFilePath || "");
        if (projectPath) {
            var projectDir = dirname(projectPath);
            add(projectDir);
            add(projectDir.replace(/\/developer\/assets\/tiled$/, ""));
            add(projectDir.replace(/\/tiled$/, ""));
        }

        // 3. This extension script's own location, when Tiled exposes it.
        var scriptPath = normalizePath(typeof __filename === "string" ? __filename : "");
        if (scriptPath) {
            var ia = scriptPath.indexOf("/developer/assets/tiled/extensions/");
            if (ia >= 0) add(scriptPath.slice(0, ia));
            var ib = scriptPath.indexOf("/tiled/extensions/");
            if (ib >= 0) add(scriptPath.slice(0, ib));
        }

        return roots;
    }

    // The toolkit whose MVTK.tiled-project is open, or "" when the open project
    // (if any) is not a toolkit. The project file sits at the toolkit root; also
    // accept it nested under /tiled or the assets path.
    function openProjectRoot() {
        var projectPath = normalizePath(tiled.projectFilePath || "");
        if (!projectPath) return "";
        var projectDir = dirname(projectPath).replace(/\/+$/, "");
        var candidates = [
            projectDir,
            projectDir.replace(/\/developer\/assets\/tiled$/, ""),
            projectDir.replace(/\/tiled$/, "")
        ];
        for (var i = 0; i < candidates.length; i++) {
            if (looksLikeRoot(candidates[i])) return candidates[i];
        }
        return "";
    }

    function detectProjectRoot() {
        // The toolkit whose Tiled project is open always wins. Switching toolkits
        // is just opening another MVTK.tiled-project, with nothing to install on
        // any OS, and a stale export_path.txt (a copied toolkit, or an older
        // global install pointing at another toolkit) cannot redirect exports.
        var projectRoot = openProjectRoot();
        if (projectRoot) return projectRoot;

        // No toolkit project is open. When the extension is installed globally,
        // __filename points at Tiled's user extensions folder; INSTALL.bat /
        // INSTALL.sh write export_path.txt next to that copy so export still
        // works and does not depend on where the .tmx was saved.
        var scriptDirOverride = readOverrideNextToExtension();
        if (scriptDirOverride) return scriptDirOverride;

        var roots = candidateRoots();

        // An explicit export_path.txt override always wins, wherever we can
        // locate it relative to a candidate root.
        for (var i = 0; i < roots.length; i++) {
            var override = readOverrideFrom(roots[i]);
            if (override) return override;
        }

        // Otherwise use the first candidate that actually looks like the toolkit.
        for (var j = 0; j < roots.length; j++) {
            if (looksLikeRoot(roots[j])) return roots[j];
        }

        // Last resort: first non-empty candidate (better than failing outright).
        for (var k = 0; k < roots.length; k++) {
            if (roots[k]) return roots[k];
        }

        return "";
    }

    function allMapFormatObjects() {
        var out = [];
        var formats = tiled.mapFormats || [];
        for (var i = 0; i < formats.length; i++) {
            var entry = formats[i];
            var fmt = null;

            // Tiled API exposes mapFormats as short-name strings.
            if (typeof entry === "string") {
                fmt = tiled.mapFormat(entry);
            } else if (entry && entry.canWrite !== undefined) {
                // Defensive fallback in case a future version exposes objects.
                fmt = entry;
            }

            if (fmt) out.push(fmt);
        }
        return out;
    }

    function isWritableFormat(fmt) {
        if (!fmt) return false;
        if (typeof fmt.write === "function") return true;
        if (fmt.canWrite === true) return true;
        if (typeof fmt.canWrite === "function") return true;
        return false;
    }

    function findFormatById(candidates) {
        var raw = tiled.mapFormats || [];
        for (var i = 0; i < raw.length; i++) {
            var id = String(raw[i] || "");
            var idLower = id.toLowerCase();
            for (var j = 0; j < candidates.length; j++) {
                if (idLower === String(candidates[j]).toLowerCase()) {
                    var fmt = tiled.mapFormat(id);
                    if (isWritableFormat(fmt)) return fmt;
                }
            }
        }
        return null;
    }

    function findFormatByExtension(ext) {
        var testName = "dummy." + ext;
        var formats = allMapFormatObjects();
        for (var i = 0; i < formats.length; i++) {
            var fmt = formats[i];
            if (!isWritableFormat(fmt)) continue;
            // supportsFile is not guaranteed across Tiled versions/plugins.
            if (typeof fmt.supportsFile === "function" && fmt.supportsFile(testName)) {
                return fmt;
            }
        }
        return null;
    }

    function findFormatByNameSubstring(substr) {
        var s = substr.toLowerCase();
        var formats = allMapFormatObjects();
        for (var i = 0; i < formats.length; i++) {
            var fmt = formats[i];
            if (!isWritableFormat(fmt) || !fmt.name) continue;
            if (fmt.name.toLowerCase().indexOf(s) !== -1) {
                return fmt;
            }
        }
        return null;
    }

    function writeWithFormat(format, map, path, label) {
        forgetFingerprint(path);
        try {
            var err = format.write(map, path);
            if (typeof err === "string" && err.length > 0) {
                return label + " export failed:\n" + err;
            }
            return null;
        } catch (e) {
            return label + " export failed:\n" + e;
        }
    }

    function removeFileIfPresent(path) {
        forgetFingerprint(path);
        if (!path || !fileExists(path)) return;
        if (HAS_FILE && typeof File.remove === "function") {
            try { File.remove(path); } catch (e) { /* best-effort temp cleanup */ }
        }
    }

    function moveFileOverwrite(src, dst) {
        forgetFingerprint(src);
        forgetFingerprint(dst);
        if (_g.__mvtkWorldContext) _g.__mvtkWorldContext.beforeWrite(dst);
        if (HAS_FILE && typeof File.move === "function") {
            try {
                if (File.move(src, dst, true)) return null;
                return "File.move returned false";
            } catch (e) {
                return "File.move failed (" + e + ")";
            }
        }
        var copyErr = copyOne(src, dst, false);
        if (copyErr) return copyErr;
        removeFileIfPresent(src);
        return null;
    }

    // The format plugins write into same-directory staging files. Back up every
    // previous output, publish the staged set, and restore the full set if any
    // publish fails. Callers never observe a half-updated room output set.
    function publishStagedOutputs(pairs) {
        var prepared = [];
        var i;
        for (i = 0; i < pairs.length; i++) {
            var pair = pairs[i];
            var backup = pair.finalPath + ".mvtk_backup";
            removeFileIfPresent(backup);
            var hadOriginal = fileExists(pair.finalPath);
            if (hadOriginal) {
                var backupErr = copyOne(pair.finalPath, backup, false);
                if (backupErr) {
                    removeFileIfPresent(backup);
                    for (var b = 0; b < prepared.length; b++) {
                        removeFileIfPresent(prepared[b].backupPath);
                    }
                    return "could not back up " + pair.finalPath + " (" + backupErr + ")";
                }
            }
            prepared.push({
                stagedPath: pair.stagedPath,
                finalPath: pair.finalPath,
                backupPath: backup,
                hadOriginal: hadOriginal,
                published: false
            });
        }

        for (i = 0; i < prepared.length; i++) {
            var current = prepared[i];
            var publishErr = moveFileOverwrite(current.stagedPath, current.finalPath);
            if (publishErr) {
                var rollbackErrors = [];
                for (var r = 0; r < prepared.length; r++) {
                    var rollback = prepared[r];
                    var restoreFailed = false;
                    if (rollback.hadOriginal && fileExists(rollback.backupPath)) {
                        var restoreError = moveFileOverwrite(rollback.backupPath, rollback.finalPath);
                        if (restoreError) {
                            rollbackErrors.push(rollback.finalPath + ": " + restoreError);
                            restoreFailed = true;
                        }
                    } else if (rollback.published && !rollback.hadOriginal) {
                        removeFileIfPresent(rollback.finalPath);
                    }
                    removeFileIfPresent(rollback.stagedPath);
                    // moveFileOverwrite consumes a successful backup restore;
                    // leave a failed one in place for manual recovery.
                    if (!restoreFailed) removeFileIfPresent(rollback.backupPath);
                }
                var message = "could not publish " + current.finalPath + " (" + publishErr + ")";
                if (rollbackErrors.length > 0) {
                    message += "; rollback failed for " + rollbackErrors.join("; ") +
                        " (recovery backups were kept)";
                }
                return message;
            }
            current.published = true;
        }

        for (i = 0; i < prepared.length; i++) {
            removeFileIfPresent(prepared[i].backupPath);
        }
        return null;
    }

    function readTextFile(path) {
        var file = new TextFile(path, TextFile.ReadOnly);
        var text = file.readAll();
        file.close();
        return text;
    }

    function writeTextFile(path, text) {
        forgetFingerprint(path);
        if (_g.__mvtkWorldContext) _g.__mvtkWorldContext.beforeWrite(path);
        writeWithRetry(function () {
            var file = new TextFile(path, TextFile.WriteOnly);
            file.write(text);
            // With Tiled's safe-write mode, close() without commit() discards a
            // WriteOnly TextFile. commit() both publishes and closes the file.
            if (typeof file.commit === "function") file.commit();
            else file.close();
        });
    }

    // Control-layer Z band must sit BELOW the imported background image-layer
    // band (which spans roughly -0.15..-0.01 in mvtk/editor/background_atlas.lua).
    // Tiled treats the bottom of the layer hierarchy as "behind everything", and
    // the `solid` layer is authored at the bottom of every room. Keeping the
    // control-layer band at -0.30..-0.20 guarantees `solid` (and bounds, doors,
    // etc.) render behind every imported background image, matching Tiled.
    var controlLayerZBase = -0.3;
    var controlLayers = {
        bounds: true,
        grapple: true,
        solid: true,
        wall: true,
        walls: true,
        ceiling: true,
        ceilings: true,
        ground: true,
        floor: true,
        floors: true,
        collision: true,
        collisions: true,
        locked_door: true,
        door_left: true,
        door_right: true,
        door_top: true,
        door_bottom: true,
        door_up: true,
        door_down: true
    };

    function normalizeLayerName(name) {
        return String(name || "")
            .toLowerCase()
            .replace(/[\s\-]+/g, "_")
            .replace(/[^\w_]/g, "_")
            .replace(/_+/g, "_")
            .replace(/^_+/, "")
            .replace(/_+$/, "");
    }

    function formatLayerZ(value) {
        return String(Math.round(value * 1000000) / 1000000);
    }

    function postProcessDefoldTilemapDepth(path) {
        var text = readTextFile(path);
        var newline = text.indexOf("\r\n") >= 0 ? "\r\n" : "\n";
        var lines = text.split(/\r?\n/);
        var out = [];
        var block = null;
        var layerIndex = 0;

        function flushBlock() {
            if (!block) return;

            layerIndex += 1;
            var layerName = normalizeLayerName(block.id);
            if (controlLayers[layerName]) {
                var z = controlLayerZBase + (layerIndex * 0.0001);
                var replaced = false;
                for (var i = 0; i < block.lines.length; i++) {
                    if (/^\s*z:\s*/.test(block.lines[i])) {
                        block.lines[i] = block.lines[i].replace(/z:\s*[-+0-9.eE]+/, "z: " + formatLayerZ(z));
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) {
                    var insertAt = Math.min(2, block.lines.length);
                    block.lines.splice(insertAt, 0, "  z: " + formatLayerZ(z));
                }
            }

            // Grapple paint is authoring data; its static strips are baked GOs.
            // Keep it visible in Tiled while suppressing the marker tiles in game.
            if (layerName === "grapple") {
                var visibilityReplaced = false;
                for (var v = 0; v < block.lines.length; v++) {
                    if (/^\s*is_visible:\s*/.test(block.lines[v])) {
                        block.lines[v] = block.lines[v].replace(/is_visible:\s*\d+/, "is_visible: 0");
                        visibilityReplaced = true;
                        break;
                    }
                }
                if (!visibilityReplaced) block.lines.splice(Math.min(2, block.lines.length), 0, "  is_visible: 0");
            }

            for (var j = 0; j < block.lines.length; j++) out.push(block.lines[j]);
            block = null;
        }

        for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
            var line = lines[lineIndex];
            if (/^layers\s*\{\s*$/.test(line)) {
                flushBlock();
                block = { id: "", lines: [line], depth: 1 };
            } else if (block) {
                var idMatch = line.match(/^\s*id:\s*"([^"]+)"/);
                if (idMatch) block.id = idMatch[1];
                if (/^\s*\w+\s*\{\s*$/.test(line)) block.depth += 1;
                if (/^\s*\}\s*$/.test(line)) block.depth -= 1;
                block.lines.push(line);
                if (block.depth <= 0) {
                    flushBlock();
                }
            } else {
                out.push(line);
            }
        }
        flushBlock();

        var processed = out.join(newline);
        if (processed !== text) writeTextFile(path, processed);
    }

    function luaNumber(value) {
        var n = Number(value);
        if (!isFinite(n)) n = 0;
        n = Math.round(n * 1000000) / 1000000;
        if (n === 0 && 1 / n === -Infinity) n = 0;
        return String(n);
    }

    function luaString(value) {
        return "\"" + String(value || "")
            .replace(/\\/g, "\\\\")
            .replace(/"/g, "\\\"")
            .replace(/\r/g, "\\r")
            .replace(/\n/g, "\\n") + "\"";
    }

    function arrayFromListLike(value, countProp, atMethod) {
        var out = [];
        if (!value) return out;
        if (typeof value.length === "number") {
            for (var i = 0; i < value.length; i++) out.push(value[i]);
            return out;
        }
        if (typeof value[countProp] === "number" && typeof value[atMethod] === "function") {
            for (var j = 0; j < value[countProp]; j++) out.push(value[atMethod](j));
        }
        return out;
    }

    function mapTilesetsForCollision(map) {
        try {
            if (map && typeof map.usedTilesets === "function") {
                var rawUsed = map.usedTilesets();
                if (rawUsed) return arrayFromListLike(rawUsed, "length", "at");
            }
        } catch (e) { /* older Tiled builds: fall back below */ }
        return (map && map.tilesets) || [];
    }

    function tilesetTiles(ts) {
        var tiles = arrayFromListLike(ts && ts.tiles, "length", "at");
        if (tiles.length > 0) return tiles;
        if (ts && typeof ts.tileCount === "number" && typeof ts.tile === "function") {
            for (var i = 0; i < ts.tileCount; i++) {
                var tile = ts.tile(i);
                if (tile) tiles.push(tile);
            }
        }
        return tiles;
    }

    function objectGroupObjects(objectGroup) {
        var objects = arrayFromListLike(objectGroup && objectGroup.objects, "length", "at");
        if (objects.length > 0) return objects;
        return arrayFromListLike(objectGroup, "objectCount", "objectAt");
    }

    function polygonPoints(polygon) {
        var points = arrayFromListLike(polygon, "length", "at");
        if (points.length > 0) return points;
        return arrayFromListLike(polygon, "pointCount", "pointAt");
    }

    function tileLocalId(tile, fallback) {
        if (tile && tile.id !== undefined) return Number(tile.id);
        if (tile && tile.tileId !== undefined) return Number(tile.tileId);
        return fallback;
    }

    function serializeCollisionObject(object) {
        if (!object) return null;
        var x = Number(object.x) || 0;
        var y = Number(object.y) || 0;
        var width = Number(object.width) || 0;
        var height = Number(object.height) || 0;
        var polygon = polygonPoints(object.polygon);
        var shape = String(object.shape || "");
        var lines = ["              {"];

        if (object.id !== undefined) lines.push("                id = " + luaNumber(object.id) + ",");
        if (polygon.length >= 3) {
            lines.push("                shape = " + luaString("polygon") + ",");
            lines.push("                x = " + luaNumber(x) + ",");
            lines.push("                y = " + luaNumber(y) + ",");
            lines.push("                rotation = " + luaNumber(object.rotation || 0) + ",");
            lines.push("                polygon = {");
            for (var i = 0; i < polygon.length; i++) {
                lines.push("                  { x = " + luaNumber(polygon[i].x) +
                    ", y = " + luaNumber(polygon[i].y) + " }" +
                    (i + 1 < polygon.length ? "," : ""));
            }
            lines.push("                }");
        } else if (width > 0 && height > 0 && (shape === "rectangle" || !object.polygon)) {
            lines.push("                shape = " + luaString("rectangle") + ",");
            lines.push("                x = " + luaNumber(x) + ",");
            lines.push("                y = " + luaNumber(y) + ",");
            lines.push("                width = " + luaNumber(width) + ",");
            lines.push("                height = " + luaNumber(height) + ",");
            lines.push("                rotation = " + luaNumber(object.rotation || 0));
        } else {
            return null;
        }

        lines.push("              }");
        return lines.join("\n");
    }

    function serializeTileCollision(tileId, objectBlocks) {
        return [
            "        {",
            "          id = " + luaNumber(tileId) + ",",
            "          objectGroup = {",
            "            objects = {",
            objectBlocks.join(",\n"),
            "            }",
            "          }",
            "        }"
        ].join("\n");
    }

    function xmlAttr(attrText, name) {
        var m = String(attrText || "").match(new RegExp("\\b" + name + '\\s*=\\s*"([^"]*)"'));
        return m ? m[1] : null;
    }

    function xmlNumAttr(attrText, name) {
        var v = xmlAttr(attrText, name);
        if (v === null) return undefined;
        var n = Number(v);
        return isNaN(n) ? undefined : n;
    }

    function parsePolygonPointsAttr(pointsStr) {
        var pts = [];
        var pairs = String(pointsStr || "").replace(/^\s+|\s+$/g, "").split(/\s+/);
        for (var i = 0; i < pairs.length; i++) {
            if (!pairs[i]) continue;
            var xy = pairs[i].split(",");
            if (xy.length === 2) {
                var px = Number(xy[0]);
                var py = Number(xy[1]);
                if (!isNaN(px) && !isNaN(py)) pts.push({ x: px, y: py });
            }
        }
        return pts;
    }

    // Build a plain object shaped like a Tiled MapObject from raw .tsx XML so it
    // can flow through serializeCollisionObject unchanged (rectangle / polygon).
    function tsxObjectFromXml(attrs, inner) {
        var obj = {
            id: xmlNumAttr(attrs, "id"),
            x: xmlNumAttr(attrs, "x") || 0,
            y: xmlNumAttr(attrs, "y") || 0,
            width: xmlNumAttr(attrs, "width") || 0,
            height: xmlNumAttr(attrs, "height") || 0,
            rotation: xmlNumAttr(attrs, "rotation") || 0,
            shape: "",
            polygon: null
        };
        var poly = String(inner || "").match(/<polygon\b[^>]*\bpoints\s*=\s*"([^"]*)"/) ||
            String(inner || "").match(/<polyline\b[^>]*\bpoints\s*=\s*"([^"]*)"/);
        if (poly) {
            obj.polygon = parsePolygonPointsAttr(poly[1]);
            obj.shape = "polygon";
        }
        return obj;
    }

    function tsxObjectGroupBlocks(objectGroupBody) {
        var out = [];
        var objRe = /<object\b([^>]*?)(?:\/>|>([\s\S]*?)<\/object>)/g;
        var m;
        while ((m = objRe.exec(objectGroupBody)) !== null) {
            var block = serializeCollisionObject(tsxObjectFromXml(m[1], m[2] || ""));
            if (block) out.push(block);
        }
        return out;
    }

    // Recover per-tile collision shapes straight from a saved .tsx file. Tiled's
    // in-memory `tile.objectGroup` reads back empty for external tilesets that are
    // not currently open in an editor tab, so the live capture above can miss
    // shapes that are actually saved on disk. The .tsx is the source of truth the
    // Defold importer bakes from (hooks/core/tilesource.lua -> parse_tsx_tileset),
    // so parsing the same shapes here keeps the export warning and the embedded
    // Lua collision in sync with what will actually import. Best-effort: an
    // unreadable .tsx just yields no blocks and the prior empty result stands.
    function tsxCollisionBlocks(tsxPath) {
        var blocks = [];
        if (!tsxPath) return blocks;
        var text;
        try {
            text = readTextFile(tsxPath);
        } catch (e) {
            return blocks;
        }
        if (!text) return blocks;

        var tileRe = /<tile\b([^>]*)>([\s\S]*?)<\/tile>/g;
        var tileMatch;
        while ((tileMatch = tileRe.exec(text)) !== null) {
            var tileId = xmlNumAttr(tileMatch[1], "id");
            if (tileId === undefined) continue;
            var og = tileMatch[2].match(/<objectgroup\b[^>]*>([\s\S]*?)<\/objectgroup>/);
            if (!og) continue;
            var objectBlocks = tsxObjectGroupBlocks(og[1]);
            if (objectBlocks.length > 0) {
                blocks.push(serializeTileCollision(tileId, objectBlocks));
            }
        }
        return blocks;
    }

    function collectTilesetCollisionExports(map) {
        var out = [];
        var sets = mapTilesetsForCollision(map);
        for (var s = 0; s < sets.length; s++) {
            var ts = sets[s];
            if (!ts) continue;
            var blocks = [];
            var tiles = tilesetTiles(ts);
            for (var t = 0; t < tiles.length; t++) {
                var tile = tiles[t];
                if (!tile || !tile.objectGroup) continue;
                var objects = objectGroupObjects(tile.objectGroup);
                var objectBlocks = [];
                for (var o = 0; o < objects.length; o++) {
                    var block = serializeCollisionObject(objects[o]);
                    if (block) objectBlocks.push(block);
                }
                if (objectBlocks.length > 0) {
                    blocks.push(serializeTileCollision(tileLocalId(tile, t), objectBlocks));
                }
            }
            // The live read misses collision on external single-image tilesets
            // that are not open in an editor tab; recover it from the saved .tsx
            // so the warning and the embedded Lua match what Defold will bake.
            // Collections never carry tile collision, so they are left untouched.
            if (blocks.length === 0 && ts.fileName && !ts.isCollection) {
                blocks = tsxCollisionBlocks(ts.fileName);
            }
            out.push({
                name: String(ts.name || ""),
                fileName: normalizePath(ts.fileName || ""),
                external: !!ts.fileName,
                isCollection: !!ts.isCollection,
                tileCollisionCount: blocks.length,
                blocks: blocks
            });
        }
        return out;
    }

    function findMatchingBrace(text, openIndex) {
        var depth = 0;
        var quote = "";
        var escape = false;
        var lineComment = false;
        for (var i = openIndex; i < text.length; i++) {
            var c = text.charAt(i);
            var n = text.charAt(i + 1);
            if (lineComment) {
                if (c === "\n") lineComment = false;
                continue;
            }
            if (quote) {
                if (escape) {
                    escape = false;
                } else if (c === "\\") {
                    escape = true;
                } else if (c === quote) {
                    quote = "";
                }
                continue;
            }
            if (c === "-" && n === "-") {
                lineComment = true;
                i++;
                continue;
            }
            if (c === "\"" || c === "'") {
                quote = c;
                continue;
            }
            if (c === "{") {
                depth++;
            } else if (c === "}") {
                depth--;
                if (depth === 0) return i;
            }
        }
        return -1;
    }

    function directChildTables(text, openIndex, closeIndex) {
        var entries = [];
        var depth = 0;
        var quote = "";
        var escape = false;
        var lineComment = false;
        var start = -1;
        for (var i = openIndex + 1; i < closeIndex; i++) {
            var c = text.charAt(i);
            var n = text.charAt(i + 1);
            if (lineComment) {
                if (c === "\n") lineComment = false;
                continue;
            }
            if (quote) {
                if (escape) {
                    escape = false;
                } else if (c === "\\") {
                    escape = true;
                } else if (c === quote) {
                    quote = "";
                }
                continue;
            }
            if (c === "-" && n === "-") {
                lineComment = true;
                i++;
                continue;
            }
            if (c === "\"" || c === "'") {
                quote = c;
                continue;
            }
            if (c === "{") {
                depth++;
                if (depth === 1) start = i;
            } else if (c === "}") {
                if (depth === 1 && start >= 0) entries.push({ start: start, end: i });
                depth--;
            }
        }
        return entries;
    }

    function unescapeLuaString(value) {
        return String(value || "")
            .replace(/\\"/g, "\"")
            .replace(/\\\\/g, "\\");
    }

    function findTilesetEntriesInLua(text) {
        var match = /tilesets\s*=\s*\{/.exec(text);
        if (!match) return [];
        var openIndex = text.indexOf("{", match.index);
        var closeIndex = findMatchingBrace(text, openIndex);
        if (closeIndex < 0) return [];
        var children = directChildTables(text, openIndex, closeIndex);
        for (var i = 0; i < children.length; i++) {
            var body = text.slice(children[i].start, children[i].end + 1);
            var nameMatch = body.match(/\bname\s*=\s*"((?:\\"|[^"])*)"/);
            var fileMatch = body.match(/\bfilename\s*=\s*"((?:\\"|[^"])*)"/);
            children[i].name = nameMatch ? unescapeLuaString(nameMatch[1]) : "";
            children[i].fileName = fileMatch ? normalizePath(unescapeLuaString(fileMatch[1])) : "";
        }
        return children;
    }

    function findFieldTable(entryText, fieldName) {
        var re = new RegExp("\\b" + fieldName + "\\s*=\\s*\\{");
        var match = re.exec(entryText);
        if (!match) return null;
        var openIndex = entryText.indexOf("{", match.index);
        var closeIndex = findMatchingBrace(entryText, openIndex);
        if (closeIndex < 0) return null;
        return { open: openIndex, close: closeIndex };
    }

    function appendTileBlocksToEntry(entryText, blocks) {
        var tilesField = findFieldTable(entryText, "tiles");
        var joined = blocks.join(",\n");
        if (tilesField) {
            var existing = entryText.slice(tilesField.open + 1, tilesField.close);
            var trimmed = existing.replace(/\s+$/g, "");
            var separator = /\S/.test(existing) ? (trimmed.charAt(trimmed.length - 1) === "," ? "\n" : ",\n") : "\n";
            return entryText.slice(0, tilesField.close).replace(/\s+$/g, "") +
                separator + joined + "\n      " +
                entryText.slice(tilesField.close);
        }

        var closeIndex = entryText.lastIndexOf("}");
        if (closeIndex < 0) return entryText;
        var beforeClose = entryText.slice(0, closeIndex).replace(/\s+$/g, "");
        var closeIndentMatch = entryText.slice(0, closeIndex).match(/\n([ \t]*)$/);
        var closeIndent = closeIndentMatch ? closeIndentMatch[1] : "    ";
        return beforeClose + ",\n      tiles = {\n" + joined + "\n      }\n" +
            closeIndent + "}";
    }

    function sameBasename(a, b) {
        if (!a || !b) return false;
        return basename(a).toLowerCase() === basename(b).toLowerCase();
    }

    function injectTileCollisionObjectGroups(luaPath, map) {
        var captures = collectTilesetCollisionExports(map);
        var result = { captures: captures, injectedTiles: 0, error: "" };
        var text = readTextFile(luaPath);
        var entries = findTilesetEntriesInLua(text);
        if (entries.length === 0) return result;

        var replacements = [];
        var usedEntries = {};
        for (var c = 0; c < captures.length; c++) {
            var capture = captures[c];
            if (!capture.blocks || capture.blocks.length === 0) continue;
            var entryIndex = -1;
            for (var e = 0; e < entries.length; e++) {
                if (usedEntries[e]) continue;
                if ((capture.name && entries[e].name === capture.name) ||
                    sameBasename(capture.fileName, entries[e].fileName)) {
                    entryIndex = e;
                    break;
                }
            }
            if (entryIndex < 0 && entries.length === captures.length && entries[c] && !usedEntries[c]) {
                entryIndex = c;
            }
            if (entryIndex < 0) continue;
            usedEntries[entryIndex] = true;
            var entry = entries[entryIndex];
            var entryText = text.slice(entry.start, entry.end + 1);
            replacements.push({
                start: entry.start,
                end: entry.end + 1,
                value: appendTileBlocksToEntry(entryText, capture.blocks)
            });
            result.injectedTiles += capture.blocks.length;
        }

        if (replacements.length === 0) return result;
        replacements.sort(function (a, b) { return b.start - a.start; });
        for (var r = 0; r < replacements.length; r++) {
            text = text.slice(0, replacements[r].start) +
                replacements[r].value +
                text.slice(replacements[r].end);
        }
        writeTextFile(luaPath, text);
        return result;
    }

    function collectPerTileCollisionWarnings(captures, assets, paintedTileLayerSets) {
        var painted = {};
        for (var p = 0; p < (paintedTileLayerSets || []).length; p++) {
            var ts = paintedTileLayerSets[p];
            painted[String(ts.name || "") + "|" + normalizePath(ts.fileName || "")] = true;
        }
        var warnings = [];
        for (var i = 0; i < (captures || []).length; i++) {
            var capture = captures[i];
            if (!capture || !capture.external) continue;
            if (capture.isCollection) continue;
            var k = String(capture.name || "") + "|" + normalizePath(capture.fileName || "");
            if (!painted[k]) continue;
            if (capture.tileCollisionCount > 0) continue;
            var name = capture.name || basename(capture.fileName) || "(unnamed)";
            var warning = "No per-tile collision captured for tileset '" + name +
                "' — save the tileset (.tsx) in Tiled (it's a separate file from the map) before exporting.";
            var tsxName = basename(capture.fileName);
            if (tsxName && assets && assets.failedTsx && assets.failedTsx[tsxName]) {
                warning += " The .tsx copy also failed; check the copy error above.";
            }
            warnings.push(warning);
        }
        return warnings;
    }

    function listFormatNames() {
        var out = [];
        var formats = allMapFormatObjects();
        for (var i = 0; i < formats.length; i++) {
            if (formats[i] && formats[i].name) out.push(formats[i].name);
        }
        if (out.length === 0 && tiled.mapFormats && tiled.mapFormats.length) {
            // Fallback to the raw short-name list for troubleshooting.
            return String(tiled.mapFormats);
        }
        return out.join(", ");
    }

    // Read the project's configured tile size from tile_settings.lua so we can
    // warn at export time when a map or tileset does not match it -- the single
    // most common cause of rooms importing at the wrong scale.
    function readProjectTileSize(root) {
        if (!root) return null;
        try {
            var text = readTextFile(root + "/developer/config/tile_settings.lua");
            var wm = text.match(/width\s*=\s*(\d+)/);
            var hm = text.match(/height\s*=\s*(\d+)/);
            if (wm) {
                var w = parseInt(wm[1], 10);
                var h = hm ? parseInt(hm[1], 10) : w;
                if (w > 0 && h > 0) return { width: w, height: h };
            }
        } catch (e) { /* missing/unreadable: skip the project-size check */ }
        return null;
    }

    // Rewrite the project's configured tile size in tile_settings.lua (the
    // single source of truth read by readProjectTileSize and the game runtime).
    // Only the bare numeric fields in the TILE table are touched; \b guards the
    // derived helpers (half_width, tile_width, ...) that reference TILE.width.
    // Returns null on success or an error string.
    function writeProjectTileSize(root, width, height) {
        if (!root) return "No project root.";
        var path = root + "/developer/config/tile_settings.lua";
        var text;
        try {
            text = readTextFile(path);
        } catch (e) {
            return "Could not read " + path + ":\n" + e;
        }
        if (!text) return "Could not read " + path + ".";

        var updated = text
            .replace(/\bwidth\s*=\s*\d+/, "width  = " + width)
            .replace(/\bheight\s*=\s*\d+/, "height = " + height);
        if (updated === text) {
            return "Could not find the width/height fields in " + path + ".";
        }

        try {
            writeTextFile(path, updated);
        } catch (e) {
            return "Could not write " + path + ":\n" + e;
        }
        return null;
    }

    // Visit every layer, descending into group layers.
    function eachLayer(container, fn) {
        var n = container.layerCount;
        for (var i = 0; i < n; i++) {
            var layer = container.layerAt(i);
            fn(layer);
            if (layer && layer.isGroupLayer) eachLayer(layer, fn);
        }
    }

    // Distinct single-PNG (non-collection) tilesets actually painted on TILE
    // layers. Object layers are skipped, so image-collection object art never
    // counts here.
    function tilesetsPaintedOnTileLayers(map) {
        var byKey = {};
        var order = [];

        function key(ts) {
            return String(ts && ts.name || "") + "|" + normalizePath(ts && ts.fileName || "");
        }

        function note(ts) {
            if (!ts || ts.isCollection) return;
            var k = key(ts);
            if (byKey[k]) return;
            byKey[k] = ts;
            order.push(ts);
        }

        try {
            eachLayer(map, function (layer) {
                if (!layer || !layer.isTileLayer) return;
                // Marker gids may come from any tileset; grapple paint is not room art.
                if (normalizeLayerName(layer.name) === "grapple") return;

                // region() works for finite and infinite maps; fall back to
                // width/height for older Tiled builds.
                var rects = null;
                try {
                    if (typeof layer.region === "function") rects = layer.region().rects;
                } catch (e) { /* fall back below */ }

                if (rects && rects.length) {
                    for (var r = 0; r < rects.length; r++) {
                        var rc = rects[r];
                        for (var y = rc.y; y < rc.y + rc.height; y++) {
                            for (var x = rc.x; x < rc.x + rc.width; x++) {
                                var tile = layer.tileAt(x, y);
                                if (tile && tile.tileset) note(tile.tileset);
                            }
                        }
                    }
                } else {
                    var w = layer.width || 0;
                    var h = layer.height || 0;
                    for (var yy = 0; yy < h; yy++) {
                        for (var xx = 0; xx < w; xx++) {
                            var t2 = layer.tileAt(xx, yy);
                            if (t2 && t2.tileset) note(t2.tileset);
                        }
                    }
                }
            });
        } catch (e) { /* layer/API differences: best effort */ }

        return order;
    }

    function collectMultipleTilesheetWarnings(map, paintedTileLayerSets) {
        var sets = paintedTileLayerSets || [];
        if (sets.length <= 1) return [];

        // Mirror hooks/core/tilesource.lua -> pick_primary_tileset.
        var biome = "";
        try {
            if (typeof map.property === "function") biome = String(map.property("biome") || "");
        } catch (e) { /* missing property API: use first painted tileset */ }

        var primary = sets[0];
        if (biome) {
            for (var i = 0; i < sets.length; i++) {
                if (String(sets[i].name || "").toLowerCase() === biome.toLowerCase()) {
                    primary = sets[i];
                    break;
                }
            }
        }

        var names = [];
        for (var j = 0; j < sets.length; j++) names.push(sets[j].name || "(unnamed)");
        var ignored = [];
        for (var k = 0; k < sets.length; k++) {
            if (sets[k] !== primary) ignored.push(sets[k].name || "(unnamed)");
        }

        return [
            "This room paints tile layers with " + sets.length + " different tilesheets (" +
            names.join(", ") + "). Defold uses only ONE tilesheet per room for tiles and " +
            "per-tile collision, so only '" + (primary.name || "(unnamed)") + "' will import; " +
            "tiles painted from " + ignored.join(", ") + " will be missing in-engine and will " +
            "not collide. Repaint this room with a single tilesheet (merge the art into one PNG), " +
            "or split it into separate rooms — one tilesheet each. " +
            "(Image-collection object tilesets do not count and are fine to mix in.)"
        ];
    }

    // Non-blocking authoring checks surfaced in the export dialog. These catch
    // the mistakes that otherwise turn into silent "off" results downstream:
    // a missing templates layer (objects never spawn) and tile-size mismatches
    // (rooms import at the wrong scale).
    function collectAuthoringWarnings(map, root) {
        var warnings = [];

        var hasTopLevelTemplates = false;
        var hasNestedTemplates = false;
        try {
            for (var layerIndex = 0; layerIndex < map.layerCount; layerIndex++) {
                var topLayer = map.layerAt(layerIndex);
                if (topLayer && topLayer.isObjectLayer &&
                    String(topLayer.name || "").toLowerCase() === "templates") {
                    hasTopLevelTemplates = true;
                } else if (topLayer && topLayer.isGroupLayer) {
                    eachLayer(topLayer, function (nestedLayer) {
                        if (nestedLayer && nestedLayer.isObjectLayer &&
                            String(nestedLayer.name || "").toLowerCase() === "templates") {
                            hasNestedTemplates = true;
                        }
                    });
                }
            }
        } catch (e) { /* layer API differences: skip this check */ }
        if (!hasTopLevelTemplates) {
            warnings.push(
                (hasNestedTemplates
                    ? "The 'templates' object layer is nested inside a group. "
                    : "No top-level 'templates' object layer found. ") +
                "Toolkit objects (player_start, doors, enemies) must sit on the " +
                "top-level 'templates' object layer or they will not spawn. New rooms " +
                "made with File > new_room_blank already have it."
            );
        }

        var mapTW = map.tileWidth, mapTH = map.tileHeight;
        var projSize = readProjectTileSize(root);
        if (projSize && (projSize.width !== mapTW || projSize.height !== mapTH)) {
            warnings.push(
                "Map tile size is " + mapTW + "x" + mapTH + " but the project " +
                "(developer/config/tile_settings.lua) is " + projSize.width + "x" +
                projSize.height + ". Rooms import at the wrong scale when these differ. " +
                "Use the art's real tile size in Tiled, then run Import Assets to " +
                "regenerate the project tile-size mirror."
            );
        }

        var sets = map.tilesets || [];
        for (var i = 0; i < sets.length; i++) {
            var ts = sets[i];
            if (!ts || ts.isCollection) continue;
            if (ts.tileWidth !== mapTW || ts.tileHeight !== mapTH) {
                warnings.push(
                    "Tileset '" + (ts.name || "(unnamed)") + "' has " + ts.tileWidth +
                    "x" + ts.tileHeight + " tiles but the map grid is " + mapTW + "x" +
                    mapTH + "; its tiles will not align. Rebuild the tileset at " +
                    mapTW + "x" + mapTH + ", or set the map tile size to match."
                );
            }
        }

        return warnings;
    }

    function canonicalMapLocationError(mapFileName, root) {
        var expectedDir = cleanPath(root + "/developer/assets/tiled/maps");
        var actualDir = cleanPath(dirname(mapFileName));
        if (pathKey(actualDir) === pathKey(expectedDir)) return "";
        return "This map is outside the toolkit's authoring maps folder:\n  " +
            normalizePath(mapFileName) + "\n\nMove or save it under:\n  " + expectedDir +
            "\n\nExport was stopped so an external same-named map cannot overwrite a project room.";
    }

    function normalizedAbsoluteSourcePath(mapFileName, root) {
        var source = cleanPath(mapFileName);
        if (isAbsolutePath(source)) return source;
        return resolvePath(root, source);
    }

    function pathIsInsideRoot(path, root) {
        var candidate = pathKey(path);
        var rootPath = pathKey(root);
        return candidate === rootPath || candidate.indexOf(rootPath + "/") === 0;
    }

    function externalAuthoringError(source, root) {
        var visited = {};
        function inspect(path) {
            path = cleanPath(path);
            if (visited[pathKey(path)]) return "";
            visited[pathKey(path)] = true;
            // Shipped templates are framework files, preserved by Reset Project.
            if (/\.tx$/i.test(path) && pathIsInsideRoot(path, root + "/tiled/templates")) return "";
            if (authoringPathIsInsideRoot(path, root)) return "Tiled authoring sources must be outside the Defold project.\nMove this original and update its references before exporting:\n  " + path;
            if (!fileExists(path)) return "Missing external authoring source:\n  " + path;
            if (/\.(tmx|tsx|tx)$/i.test(path)) {
                var text = readTextFile(path), refs = /\b(?:source|template)=("|')([\s\S]*?)\1/g, match, error;
                while ((match = refs.exec(text)) !== null) {
                    error = inspect(resolvePath(dirname(path), decodeXmlAttribute(match[2])));
                    if (error) return error;
                }
                var props = /<property\b[^>]*>/g;
                while ((match = props.exec(text)) !== null) {
                    if (!/\btype=("|')file\1/.test(match[0])) continue;
                    var value = /\bvalue=("|')([\s\S]*?)\1/.exec(match[0]);
                    if (value && value[2]) {
                        error = inspect(resolvePath(dirname(path), decodeXmlAttribute(value[2])));
                        if (error) return error;
                    }
                }
            }
            return "";
        }
        return inspect(source);
    }

    // Resolve symlinks, junctions and substituted drives for the safety check.
    // New-room paths may not exist yet, so resolve the nearest existing parent.
    function canonicalAuthoringPath(path) {
        path = cleanPath(path);
        if (typeof FileInfo === "undefined" || typeof FileInfo.canonicalPath !== "function") return path;
        var canonical = FileInfo.canonicalPath(path);
        if (canonical) return normalizePath(canonical);
        var parent = dirname(path);
        return parent && parent !== path
            ? canonicalAuthoringPath(parent) + "/" + basename(path) : path;
    }

    function authoringPathIsInsideRoot(path, root) {
        return pathIsInsideRoot(path, root) ||
            pathIsInsideRoot(canonicalAuthoringPath(path), canonicalAuthoringPath(root));
    }

    function portableLocalizationProvenance(sourceMapPath, root) {
        var source = cleanPath(sourceMapPath);
        var projectRoot = cleanPath(root).replace(/\/+$/, "");
        if (!pathIsInsideRoot(source, projectRoot)) return normalizePath(source);
        return normalizePath(source).slice(normalizePath(projectRoot).length)
            .replace(/^\/+/, "");
    }

    function readLocalizationProvenance(tmxPath, root) {
        if (!fileExists(tmxPath)) return "";
        try {
            var text = readTextFile(tmxPath);
            var match = /<!--\s*mvtk-localized-from:\s*([\s\S]*?)\s*-->/.exec(text);
            // XML comments cannot contain "--". The writer represents the
            // second hyphen as comment text and we restore it for comparison.
            var source = match
                ? cleanPath(match[1].replace(/-&#45;/g, "--"))
                : "";
            return source && !isAbsolutePath(source)
                ? resolvePath(root, source)
                : source;
        } catch (e) {
            return "";
        }
    }

    // Protect an existing project room before any asset or staged-output write.
    // A matching provenance marker makes normal re-export silent; every other
    // collision requires an explicit confirmation (or the scripted test hook).
    function externalMapOverwriteError(finalTmxPath, room, sourceMapPath, root) {
        if (!fileExists(finalTmxPath)) return "";
        var existingSource = readLocalizationProvenance(finalTmxPath, root);
        if (existingSource && pathKey(existingSource) === pathKey(sourceMapPath)) return "";

        var message = "Room '" + room + "' already exists in the project and was not " +
            "generated from this map. Overwrite it (.tmx, .lua, .tilemap)?";
        var confirmed = false;
        if (_g && _g.__mvtkConfirmOverride !== undefined &&
            _g.__mvtkConfirmOverride !== null) {
            try {
                confirmed = (typeof _g.__mvtkConfirmOverride === "function")
                    ? !!_g.__mvtkConfirmOverride(message, "Overwrite project room?")
                    : !!_g.__mvtkConfirmOverride;
            } catch (e) {
                return "Could not confirm whether to overwrite room '" + room + "': " + e;
            }
        } else if (typeof tiled.confirm === "function") {
            confirmed = !!tiled.confirm(message, "Overwrite project room?");
        } else {
            return message + "\n\nExport stopped because confirmation is unavailable; " +
                "the existing room was left unchanged.";
        }
        if (!confirmed) {
            return "Export cancelled. Existing room '" + room + "' was left unchanged.";
        }
        return "";
    }

    // Rewrite the selected map-level file property in serialized TMX. This is
    // deliberately text-only: the author's open map and source TMX are never
    // mutated through Tiled's setProperty API.
    function relinkLocalizedTmxMusicPath(text, assets) {
        var music = assets && assets.music;
        if (!music || !music.relinked) {
            return { text: text, count: 0, error: "" };
        }

        var mapOpen = /<map\b[^>]*>/.exec(text);
        if (!mapOpen) {
            return { text: text, count: 0, error: "map element is missing" };
        }
        var afterMap = mapOpen.index + mapOpen[0].length;
        var propertiesOpen = /^\s*<properties\b[^>]*>/.exec(text.slice(afterMap));
        if (!propertiesOpen) {
            return { text: text, count: 0, error: "map properties element is missing" };
        }
        var propertiesStart = afterMap + propertiesOpen.index;
        var propertiesBodyStart = afterMap + propertiesOpen.index +
            propertiesOpen[0].length;
        var propertiesEnd = text.indexOf("</properties>", propertiesBodyStart);
        if (propertiesEnd < 0) {
            return { text: text, count: 0, error: "map properties element is malformed" };
        }

        var propertiesText = text.slice(propertiesStart, propertiesEnd);
        var found = false;
        var changed = false;
        propertiesText = propertiesText.replace(/<property\b[^>]*\/?\s*>/g,
            function (tag) {
                var nameMatch = /\bname\s*=\s*(["'])(.*?)\1/.exec(tag);
                var typeMatch = /\btype\s*=\s*(["'])(.*?)\1/.exec(tag);
                if (!nameMatch || decodeXmlAttribute(nameMatch[2]) !==
                    music.propertyName || !typeMatch ||
                    decodeXmlAttribute(typeMatch[2]).toLowerCase() !== "file") {
                    return tag;
                }
                var valuePattern = /(\bvalue\s*=\s*)(["'])(.*?)\2/;
                var valueMatch = valuePattern.exec(tag);
                if (!valueMatch) return tag;
                found = true;
                if (normalizePath(decodeXmlAttribute(valueMatch[3])) ===
                    music.relativePath) {
                    return tag;
                }
                changed = true;
                return tag.replace(valuePattern, function (_, prefix, quote) {
                    return prefix + quote +
                        encodeXmlAttribute(music.relativePath) + quote;
                });
            });

        if (!found) {
            return {
                text: text,
                count: 0,
                error: "localized room music property '" +
                    music.propertyName + "' is missing"
            };
        }
        if (changed) {
            text = text.slice(0, propertiesStart) + propertiesText +
                text.slice(propertiesEnd);
        }
        return { text: text, count: changed ? 1 : 0, error: "" };
    }

    function buildLocalizedTmxText(stagedTmxPath, sourceMapPath, root, assets) {
        var text;
        try {
            text = readTextFile(stagedTmxPath);
        } catch (e) {
            return { text: "", count: 0, externalTemplates: [], error: "could not read staged TMX (" + e + ")" };
        }

        var count = 0;
        var unresolved = [];
        var stageDir = dirname(stagedTmxPath);
        text = text.replace(/(<tileset\b[^>]*\bsource=)(["'])(.*?)\2/g,
            function (full, prefix, quote, encodedSource) {
                var source = decodeXmlAttribute(encodedSource);
                var sourcePath = resolvePath(stageDir, source);
                if (pathIsInsideRoot(sourcePath, root)) return full;
                var relink = successfulRelinkForSource(
                    (assets && assets.tsxRelinks) || [], sourcePath
                );
                if (!relink) {
                    unresolved.push("tileset " + (source || "(empty source)"));
                    return full;
                }
                var relinked = "../tilesets/" + basename(relink.localPath || sourcePath);
                if (normalizePath(source) !== relinked) count++;
                return prefix + quote + encodeXmlAttribute(relinked) + quote;
            });

        // Tiled serializes embedded tilesets directly into the localized TMX.
        // Relink a sheet image to tilesheets/, or every image-collection tile
        // image to backgrounds/ using the same tracker as the Lua post-pass.
        text = text.replace(/<tileset\b(?![^>]*\bsource=)[^>]*>[\s\S]*?<\/tileset>/g,
            function (block) {
                var imagePattern = /(<image\b[^>]*\bsource=)(["'])(.*?)\2/;
                var imageMatch = imagePattern.exec(block);
                var firstTile = block.search(/<tile\b/);
                if (imageMatch && (firstTile < 0 || imageMatch.index < firstTile)) {
                    var source = decodeXmlAttribute(imageMatch[3]);
                    var sourcePath = resolvePath(stageDir, source);
                    var relink = successfulRelinkForSource(
                        (assets && assets.sheetRelinks) || [], sourcePath
                    );
                    if (!relink) {
                        unresolved.push("embedded tileset image " +
                            (source || "(empty source)"));
                        return block;
                    }
                    var relinked = "../../tilesheets/" +
                        basename(relink.localPath || sourcePath);
                    if (normalizePath(source) !== relinked) count++;
                    return block.slice(0, imageMatch.index) + imageMatch[1] +
                        imageMatch[2] + encodeXmlAttribute(relinked) + imageMatch[2] +
                        block.slice(imageMatch.index + imageMatch[0].length);
                }

                return block.replace(/<tile\b[\s\S]*?<\/tile>/g, function (tileBlock) {
                    return tileBlock.replace(
                        /(<image\b[^>]*\bsource=)(["'])(.*?)\2/g,
                        function (full, prefix, quote, encodedSource) {
                            var collectionSource = decodeXmlAttribute(encodedSource);
                            var collectionSourcePath = resolvePath(
                                stageDir, collectionSource
                            );
                            var collectionRelink = successfulRelinkForSource(
                                (assets && assets.collectionImageRelinks) || [],
                                collectionSourcePath
                            );
                            if (!collectionRelink) {
                                unresolved.push("embedded collection image " +
                                    (collectionSource || "(empty source)"));
                                return full;
                            }
                            var collectionRelinked = "../backgrounds/" +
                                basename(collectionRelink.localPath ||
                                    collectionSourcePath);
                            if (normalizePath(collectionSource) !== collectionRelinked) {
                                count++;
                            }
                            return prefix + quote +
                                encodeXmlAttribute(collectionRelinked) + quote;
                        });
                });
            });

        text = text.replace(/<imagelayer\b[\s\S]*?<\/imagelayer>/g, function (block) {
            return block.replace(/(<image\b[^>]*\bsource=)(["'])(.*?)\2/g,
                function (full, prefix, quote, encodedSource) {
                    var source = decodeXmlAttribute(encodedSource);
                    var sourcePath = resolvePath(stageDir, source);
                    var relink = successfulRelinkForSource(
                        (assets && assets.imageRelinks) || [], sourcePath
                    );
                    if (!relink) {
                        unresolved.push("image layer " + (source || "(empty source)"));
                        return full;
                    }
                    var relinked = "../backgrounds/" +
                        basename(relink.localPath || sourcePath);
                    if (normalizePath(source) !== relinked) count++;
                    return prefix + quote + encodeXmlAttribute(relinked) + quote;
                });
        });

        var musicRelink = relinkLocalizedTmxMusicPath(text, assets);
        if (musicRelink.error) {
            unresolved.push("room music " + musicRelink.error);
        } else {
            text = musicRelink.text;
            count += musicRelink.count;
        }
        var enemyRelink = relinkLocalizedTmxEnemyArt(text, assets);
        if (enemyRelink.error) unresolved.push("enemy art " + enemyRelink.error);
        else { text = enemyRelink.text; count += enemyRelink.count; }

        if (unresolved.length > 0) {
            return {
                text: "",
                count: count,
                externalTemplates: [],
                error: "could not localize TMX reference(s): " + unresolved.join(", ")
            };
        }

        var externalTemplates = [];
        var seenTemplates = {};
        var templatePattern = /\btemplate=(["'])(.*?)\1/g;
        var templateMatch;
        while ((templateMatch = templatePattern.exec(text)) !== null) {
            var templateSource = decodeXmlAttribute(templateMatch[2]);
            var templatePath = resolvePath(stageDir, templateSource);
            if (!pathIsInsideRoot(templatePath, root) && !seenTemplates[pathKey(templatePath)]) {
                seenTemplates[pathKey(templatePath)] = true;
                externalTemplates.push(normalizePath(templatePath));
            }
        }

        var markerPath = portableLocalizationProvenance(sourceMapPath, root)
            .replace(/--/g, "-&#45;");
        var marker = "<!-- mvtk-localized-from: " + markerPath + " -->";
        var declaration = /^(\uFEFF?<\?xml[^>]*\?>)(\r?\n)?/;
        if (declaration.test(text)) {
            text = text.replace(declaration, function (_, xml) {
                return xml + "\n" + marker + "\n";
            });
        } else {
            text = marker + "\n" + text;
        }
        return {
            text: text,
            count: count,
            externalTemplates: externalTemplates,
            error: ""
        };
    }

    function publishLocalizedTmx(map, sourceMapPath, stagedTmxPath, root, assets) {
        var tmxFormat = null;
        try { tmxFormat = tiled.mapFormat("tmx"); }
        catch (e) { return { count: 0, externalTemplates: [], error: "TMX export failed:\n" + e }; }
        if (!tmxFormat || typeof tmxFormat.write !== "function") {
            return { count: 0, externalTemplates: [], error: "No writable TMX format is available." };
        }
        var writeError = writeWithFormat(tmxFormat, map, stagedTmxPath, "Localized TMX");
        if (writeError) return { count: 0, externalTemplates: [], error: writeError };

        var localized = buildLocalizedTmxText(
            stagedTmxPath, sourceMapPath, root, assets
        );
        if (localized.error) return localized;
        try {
            writeTextFile(stagedTmxPath, localized.text);
            if (!fileExists(stagedTmxPath) ||
                readTextFile(stagedTmxPath) !== localized.text) {
                return {
                    count: 0,
                    externalTemplates: [],
                    error: "localized TMX verification failed"
                };
            }
        } catch (e2) {
            return {
                count: 0,
                externalTemplates: [],
                error: "could not publish localized TMX staging file (" + e2 + ")"
            };
        }
        return localized;
    }

    function unsavedTilesetName(map) {
        var sets = (map && map.tilesets) || [];
        for (var i = 0; i < sets.length; i++) {
            if (sets[i] && sets[i].modified) {
                return sets[i].fileName || sets[i].name || "(unnamed tileset)";
            }
        }
        return "";
    }

    // Export from a fresh disk read, not the possibly stale object held by an
    // editor tab. This makes the saved TMX the source of truth and fixes the
    // common case where Tiled remained open while the repository map changed.
    function readSavedMap(mapFileName) {
        var format = null;
        try {
            if (typeof tiled.mapFormatForFile === "function") {
                format = tiled.mapFormatForFile(mapFileName);
            }
            if (!format) format = tiled.mapFormat("tmx");
        } catch (e) {
            return { map: null, error: "Could not select a reader for " + mapFileName + ":\n" + e };
        }
        if (!format || typeof format.read !== "function") {
            return { map: null, error: "No readable Tiled map format is available for " + mapFileName };
        }
        try {
            var fresh = format.read(mapFileName);
            if (!fresh || !fresh.isTileMap) {
                return { map: null, error: "Could not reload the saved map from disk: " + mapFileName };
            }
            return { map: fresh, error: "" };
        } catch (e2) {
            return { map: null, error: "Could not reload the saved map from disk:\n" + e2 };
        }
    }

    // Mirror EnemySkinSync.sanitize_skin_id, including Lua's ASCII byte rules.
    // The whole folder basename is used (a dot is removed, not an extension).
    function sanitizeEnemySkinId(folder) {
        var id = basename(folder).replace(/[A-Z]/g, function (c) { return c.toLowerCase(); })
            .replace(/[ \t\r\n\f\v-]+/g, "_").replace(/[^a-z0-9_]/g, "")
            .replace(/_+/g, "_").replace(/^_+|_+$/g, "");
        if (!id) return { id: null, error: "sanitized skin id is empty" };
        if (id === "none") return { id: null, error: "skin id 'none' is reserved" };
        return { id: id, error: "" };
    }

    function isEnemyFrame(name) { return /^[a-z0-9_]+_[0-9]+\.png$/i.test(name); }
    function isEnemyAsset(name) {
        return isEnemyFrame(name) || name === "collisionobject.collisionobject";
    }
    function isProjectEnemyAsset(name) {
        // Directly supplied skins also support idle.png and other unnumbered
        // frames. Protect those existing files even though links use NN names.
        return /\.png$/i.test(name) || name === "collisionobject.collisionobject";
    }

    function resolvedObjectProperty(object, name) {
        // Tiled's property() excludes template/class defaults; resolvedProperty
        // includes them. Desktop test doubles can supply the simpler accessor.
        if (typeof object.resolvedProperty === "function") return object.resolvedProperty(name);
        return typeof object.property === "function" ? object.property(name) : undefined;
    }

    function removeTrackedEnemyFile(path, tracker) {
        if (!fileExists(path)) return null;
        if (!HAS_FILE || typeof File.remove !== "function") return "File.remove is unavailable";
        var error = prepareTrackedDestination(path, tracker);
        if (error) return error;
        if (_g.__mvtkWorldContext) _g.__mvtkWorldContext.beforeWrite(path);
        forgetFingerprint(path);
        try { File.remove(path); }
        catch (e) { return "could not remove " + path + " (" + e + ")"; }
        return fileExists(path) ? "file still exists after removal: " + path : null;
    }

    function localizeEnemyArt(map, root, tracker, relationshipRecords) {
        var art = { objects: [], sourceFiles: [], localFiles: [], copied: [], warnings: [] };
        var failed = [], folders = {}, mapDir = dirname(map.fileName);
        var recordsById = {};
        (relationshipRecords || []).forEach(function (record) { recordsById[record.object_id] = record; });
        function remember(list, path) { if (list.indexOf(path) < 0) list.push(path); }
        eachLayer(map, function (layer) {
            if (!layer || !layer.isObjectLayer) return;
            var objects = layer.objects || [];
            for (var i = 0; i < objects.length; i++) {
                var object = objects[i];
                // Native template instances can have blank className/type and
                // numeric enum wrappers. Reuse the relationship collector's
                // existing template-signature and enum-name normalization.
                var record = recordsById[object.id];
                if (String((record && record.type) || object.className || object.type || "").toLowerCase() !== "enemy") continue;
                var selected = propertyToString(resolvedObjectProperty(object, "art"));
                if (!selected) continue;
                var source = resolvePath(mapDir, selected), sourceDir = dirname(source);
                var label = "enemy object " + object.id;
                if (authoringPathIsInsideRoot(sourceDir, root)) {
                    failed.push(label + ": art must link to an original outside the Defold project: " + source);
                    continue;
                }
                if (!fileExists(source) || !isEnemyFrame(basename(source))) {
                    failed.push(label + ": art must point to an existing <state>_<NN>.png frame: " + source);
                    continue;
                }
                var sanitized = sanitizeEnemySkinId(sourceDir);
                if (sanitized.error) { failed.push(label + ": " + sanitized.error); continue; }
                var id = sanitized.id, destinationDir = root + "/developer/assets/enemies/" + id;
                var sourceKey = pathKey(canonicalAuthoringPath(sourceDir));
                var folder = folders[id];
                if (!folder) {
                    folder = { sourceKey: sourceKey, localNames: [], retained: false };
                    folders[id] = folder;
                    var sourceNames, destinationNames;
                    try {
                        sourceNames = File.directoryEntries(sourceDir, File.Files).filter(isEnemyAsset).sort();
                        destinationNames = File.directoryEntries(destinationDir, File.Files).sort();
                    } catch (listError) {
                        failed.push(label + ": could not list skin folder (" + listError + ")");
                        continue;
                    }
                    for (var s = 0; s < sourceNames.length; s++) {
                        remember(art.sourceFiles, sourceDir + "/" + sourceNames[s]);
                    }
                    // An unreceipted project skin is content too. Claim a folder
                    // only when every existing asset's receipt names this source.
                    for (var d = 0; d < destinationNames.length; d++) {
                        var localName = destinationNames[d];
                        if (!isProjectEnemyAsset(localName)) continue;
                        folder.localNames.push(localName);
                        var receiptSource = "";
                        try { receiptSource = readTextFile(destinationDir + "/" + localName + ".mvtk-source").split(/\r?\n/)[0]; }
                        catch (receiptError) { /* no receipt: preserve creator content */ }
                        if (!receiptSource || pathKey(canonicalAuthoringPath(dirname(receiptSource))) !== sourceKey) {
                            folder.retained = true;
                        }
                    }
                    if (folder.retained) {
                        art.warnings.push("Skin '" + id + "' already contains project art from a different or unrecorded source; kept the project copy.");
                    } else {
                        ensureDir(destinationDir);
                        for (var c = 0; c < sourceNames.length; c++) {
                            var name = sourceNames[c], localPath = destinationDir + "/" + name;
                            var copyError = copyTracked(sourceDir + "/" + name, localPath, true, tracker);
                            if (copyError) failed.push(label + ": " + name + ": " + copyError);
                            else remember(art.copied, id + "/" + name);
                        }
                        // Only removed frames are pruned. Other creator files,
                        // including a custom collider, retain their existing role.
                        for (var p = 0; p < folder.localNames.length; p++) {
                            var oldName = folder.localNames[p];
                            if (!isEnemyFrame(oldName) || sourceNames.indexOf(oldName) >= 0) continue;
                            var oldPath = destinationDir + "/" + oldName;
                            var pruneError = removeTrackedEnemyFile(oldPath, tracker) ||
                                removeTrackedEnemyFile(oldPath + ".mvtk-source", tracker);
                            if (pruneError) failed.push(label + ": " + pruneError);
                        }
                        folder.localNames = sourceNames.slice();
                        // A retained optional collider still belongs to the
                        // imported graph even when the source no longer has one.
                        if (fileExists(destinationDir + "/collisionobject.collisionobject") &&
                            folder.localNames.indexOf("collisionobject.collisionobject") < 0) {
                            folder.localNames.push("collisionobject.collisionobject");
                        }
                    }
                    for (var a = 0; a < folder.localNames.length; a++) {
                        remember(art.localFiles, destinationDir + "/" + folder.localNames[a]);
                    }
                } else if (folder.sourceKey !== sourceKey) {
                    art.warnings.push("Skin '" + id + "' is already linked from another source in this export; kept the project copy.");
                    var otherNames = File.directoryEntries(sourceDir, File.Files).filter(isEnemyAsset);
                    for (var o = 0; o < otherNames.length; o++) remember(art.sourceFiles, sourceDir + "/" + otherNames[o]);
                }
                var frameName = basename(source);
                if (folder.localNames.indexOf(frameName) < 0) {
                    frameName = folder.localNames.filter(function (name) { return /\.png$/i.test(name); })[0];
                }
                if (!frameName) { failed.push(label + ": kept project skin has no frame to link"); continue; }
                var enemyType = propertyToString(record ? record.properties.enemy_type : resolvedObjectProperty(object, "enemy_type"));
                if (!enemyType || enemyType === "default" || enemyType === "none") enemyType = id;
                art.objects.push({ id: object.id, skin: id, enemyType: enemyType,
                    relativePath: "../../enemies/" + id + "/" + frameName });
            }
        });
        return { art: art, failed: failed };
    }

    // Both native exporters serialize independently. Rewrite their outputs by
    // object id, without changing the saved or open authoring objects.
    function rewriteEnemyLuaText(text, art) {
        if (!art || !art.objects.length) return { text: text, count: 0, error: "" };
        var layers = findFieldTable(text, "layers"), edits = [], found = {};
        if (!layers) return { text: text, count: 0, error: "map layers table is missing" };
        var objectsPattern = /\bobjects\s*=\s*\{/g, match;
        objectsPattern.lastIndex = layers.open;
        while ((match = objectsPattern.exec(text)) && match.index < layers.close) {
            var open = text.indexOf("{", match.index), close = findMatchingBrace(text, open);
            var entries = directChildTables(text, open, close);
            for (var i = 0; i < entries.length; i++) {
                var entry = entries[i], block = text.slice(entry.start, entry.end + 1);
                var idMatch = /^\{\s*id\s*=\s*(\d+)\s*,/.exec(block);
                if (!idMatch) continue;
                var record = null;
                for (var r = 0; r < art.objects.length; r++) if (art.objects[r].id === Number(idMatch[1])) record = art.objects[r];
                if (!record) continue;
                var values = { art: record.relativePath, skin: record.skin, enemy_type: record.enemyType };
                var properties = findFieldTable(block, "properties"), body = properties ? block.slice(properties.open + 1, properties.close) : "";
                Object.keys(values).forEach(function (key) {
                    var pattern = new RegExp('(\\["' + key + '"\\]\\s*=\\s*)("(?:\\\\.|[^"\\\\])*"|\'(?:\\\\.|[^\'\\\\])*\')');
                    if (pattern.test(body)) body = body.replace(pattern, function (_, prefix) { return prefix + JSON.stringify(values[key]); });
                    else {
                        body = body.replace(/\s*$/, "");
                        if (body && !/,$/.test(body)) body += ",";
                        body += '\n          ["' + key + '"] = ' + JSON.stringify(values[key]) + ",\n        ";
                    }
                });
                if (properties) block = block.slice(0, properties.open + 1) + body + block.slice(properties.close);
                else block = block.slice(0, -1).replace(/\s*$/, "").replace(/([^,])$/, "$1,") + "\n        properties = {" + body + "}\n      }";
                edits.push({ start: entry.start, end: entry.end + 1, text: block });
                found[record.id] = (found[record.id] || 0) + 1;
            }
            objectsPattern.lastIndex = close + 1;
        }
        for (var f = 0; f < art.objects.length; f++) {
            if (found[art.objects[f].id] !== 1) return { text: text, count: 0, error: "linked enemy object " + art.objects[f].id + " is missing or duplicated in Lua" };
        }
        edits.sort(function (a, b) { return b.start - a.start; });
        for (var e = 0; e < edits.length; e++) text = text.slice(0, edits[e].start) + edits[e].text + text.slice(edits[e].end);
        return { text: text, count: edits.length, error: "" };
    }

    function relinkExportedLuaEnemyArt(luaPath, assets) {
        try {
            var result = rewriteEnemyLuaText(readTextFile(luaPath), assets && assets.enemyArt);
            if (!result.error && result.count) writeTextFile(luaPath, result.text);
            return result;
        } catch (e) { return { count: 0, error: "could not relink enemy art (" + e + ")" }; }
    }

    function relinkLocalizedTmxEnemyArt(text, assets) {
        var art = assets && assets.enemyArt, found = {}, count = 0;
        if (!art || !art.objects.length) return { text: text, count: 0, error: "" };
        // Tileset collision objects have their own ids. They precede the map
        // layers and must never be mistaken for placed room enemies.
        var afterTilesets = text.lastIndexOf("</tileset>") + "</tileset>".length;
        text = text.replace(/<object\b[^>]*\/>|<object\b[^>]*>[\s\S]*?<\/object>/g, function (block, offset) {
            if (offset < afterTilesets) return block;
            var idMatch = /\bid\s*=\s*(["'])(\d+)\1/.exec(block);
            if (!idMatch) return block;
            var record = null;
            for (var r = 0; r < art.objects.length; r++) if (art.objects[r].id === Number(idMatch[2])) record = art.objects[r];
            if (!record) return block;
            if (/\/>$/.test(block)) block = block.replace(/\/>$/, ">\n</object>");
            var propsOpen = /<properties\b[^>]*>/.exec(block), propsClose = -1;
            if (propsOpen) {
                var tokens = /<\/?properties\b[^>]*>/g, depth = 0, token;
                tokens.lastIndex = propsOpen.index;
                while ((token = tokens.exec(block))) {
                    depth += /^<\//.test(token[0]) ? -1 : 1;
                    if (depth === 0) { propsClose = token.index; break; }
                }
                if (propsClose < 0) throw new Error("malformed properties for enemy object " + record.id);
            } else {
                block = block.replace(/<\/object>$/, " <properties>\n </properties>\n</object>");
                propsOpen = /<properties>/.exec(block);
                propsClose = block.indexOf("</properties>", propsOpen.index);
            }
            var bodyStart = propsOpen.index + propsOpen[0].length;
            var body = block.slice(bodyStart, propsClose);
            var values = { art: record.relativePath, skin: record.skin, enemy_type: record.enemyType };
            Object.keys(values).forEach(function (name) {
                var replaced = false;
                body = body.replace(/<property\b[^>]*\/\s*>/g, function (tag) {
                    var named = /\bname\s*=\s*(["'])(.*?)\1/.exec(tag);
                    if (!named || decodeXmlAttribute(named[2]) !== name) return tag;
                    replaced = true;
                    return '<property name="' + name + '"' + (name === "art" ? ' type="file"' : '') + ' value="' + encodeXmlAttribute(values[name]) + '"/>';
                });
                if (!replaced) body += '  <property name="' + name + '"' + (name === "art" ? ' type="file"' : '') + ' value="' + encodeXmlAttribute(values[name]) + '"/>\n ';
            });
            count++; found[record.id] = (found[record.id] || 0) + 1;
            return block.slice(0, bodyStart) + body + block.slice(propsClose);
        });
        for (var f = 0; f < art.objects.length; f++) {
            if (found[art.objects[f].id] !== 1) return { text: text, count: 0, error: "linked enemy object " + art.objects[f].id + " is missing or duplicated in TMX" };
        }
        return { text: text, count: count, error: "" };
    }

    // Map property names the Defold-side music sync accepts, mirrored from
    // hooks/editor_commands.lua -> MAP_MUSIC_PROPERTY_NAMES.
    var MUSIC_PROPERTY_NAMES = ["music", "Music", "ambience", "Ambience"];
    // Extension sets mirrored from mvtk/audio/music_sync.lua: RECOGNIZED marks a
    // value as a sound file at all; SUPPORTED is what Defold can actually play.
    var RECOGNIZED_MUSIC_EXTENSIONS = {
        ogg: true, wav: true, mp3: true, flac: true, m4a: true, aac: true, opus: true
    };
    var SUPPORTED_MUSIC_EXTENSIONS = { ogg: true, wav: true };

    // Resolve the first music property accepted by the Defold-side sync. The
    // returned record is also the single source of truth for Lua/TMX relinks,
    // so aliases such as `ambience` cannot accidentally rewrite a different
    // property later in the transaction.
    function collectRoomMusic(map, root) {
        var result = {
            file: "",
            path: "",
            propertyName: "",
            extension: "",
            supported: false,
            sourcePath: "",
            localPath: "",
            relativePath: "",
            copied: false,
            relinked: false,
            warnings: []
        };

        var raw = "";
        for (var i = 0; i < MUSIC_PROPERTY_NAMES.length; i++) {
            var value = propertyToString(safeMapProperty(map, MUSIC_PROPERTY_NAMES[i]));
            value = String(value || "").replace(/^\s+|\s+$/g, "");
            if (value) {
                raw = value;
                result.propertyName = MUSIC_PROPERTY_NAMES[i];
                break;
            }
        }
        if (!raw) return result;

        var lower = raw.toLowerCase();
        if (lower === "none" || lower === "hush") return result;

        var extMatch = raw.match(/\.([^.\\/]+)$/);
        var ext = extMatch ? extMatch[1].toLowerCase() : "";
        if (!ext || !RECOGNIZED_MUSIC_EXTENSIONS[ext]) {
            // Legacy / non-file value (e.g. an old enum id) -- not a sound file.
            return result;
        }

        result.file = basename(raw);
        result.path = raw;
        result.extension = ext;
        result.supported = !!SUPPORTED_MUSIC_EXTENSIONS[ext];
        var mapPath = propertyToString(map && map.fileName);
        if (mapPath && !isAbsolutePath(mapPath)) {
            mapPath = resolvePath(root, mapPath);
        }
        var mapDir = mapPath
            ? dirname(mapPath)
            : root + "/developer/assets/tiled/maps";
        result.sourcePath = resolvePath(mapDir, raw);
        result.localPath = root + "/developer/assets/music/" + result.file;
        result.relativePath = "../../music/" + result.file;

        if (!result.supported) {
            result.warnings.push(
                "Room music '" + result.file + "' is ." + ext + " -- Defold plays only " +
                ".ogg and .wav. Convert it and update the map's music property."
            );
        }

        return result;
    }

    // Localize supported external (or stale/missing) music references into the
    // canonical project music directory. Existing project files win basename
    // collisions, matching the Defold-side Sync Music policy.
    function localizeRoomMusic(map, root, tracker) {
        var music = collectRoomMusic(map, root);
        var result = { music: music, copied: [], failed: [] };
        if (!music.file || !music.supported) return result;

        var sourceExists = fileExists(music.sourcePath);
        var targetExists = fileExists(music.localPath);
        var needsLocalization = !pathIsInsideRoot(music.sourcePath, root) ||
            !sourceExists;
        if (!needsLocalization) return result;

        if (targetExists) {
            music.relinked = true;
            if (sourceExists &&
                !binaryFilesEqual(music.sourcePath, music.localPath)) {
                music.warnings.push(
                    "Room music basename collision: source '" +
                    normalizePath(music.sourcePath) + "' differs from existing project file '" +
                    normalizePath(music.localPath) +
                    "'. Keeping and relinking to the project file."
                );
            }
            return result;
        }

        if (!sourceExists) {
            music.warnings.push(
                "Room music file not found: " + music.path +
                ". Check the map's music property."
            );
            return result;
        }

        ensureDir(dirname(music.localPath));
        var copyError = copyTracked(
            music.sourcePath, music.localPath, true, tracker
        );
        if (copyError) {
            result.failed.push(music.file + ": " + copyError);
            return result;
        }
        music.copied = true;
        music.relinked = true;
        result.copied.push(music.file);
        return result;
    }

    var action = tiled.registerAction("MVTK.ExportLuaAndDefold", function () {
        var memoOwned = beginFingerprintMemo();
        var luaStagePath = "";
        var tilemapStagePath = "";
        var tmxStagePath = "";
        var assets = null;
        try {
            if (_g) {
                _g.__mvtkLastExportError = "";
                _g.__mvtkLastExportSummary = "";
            }
            var isBatchMode = !!(_g && _g.__mvtkBatchExportMap);
            // The command-line evaluator has no editor/activeAsset. This
            // narrow regression hook supplies a disk-read map while keeping
            // the real interactive branch (including provenance confirms).
            var interactiveTestMap = (!isBatchMode && _g)
                ? _g.__mvtkInteractiveExportMap
                : null;
            var map = isBatchMode
                ? _g.__mvtkBatchExportMap
                : (interactiveTestMap || tiled.activeAsset);
            if (!map || !map.isTileMap) {
                reportExportFailure("Open a tile map first.");
                return;
            }
            var mapFileName = map.fileName ||
                ((_g && _g.__mvtkBatchExportSourcePath) ? _g.__mvtkBatchExportSourcePath : "") ||
                ((_g && _g.__mvtkInteractiveExportSourcePath)
                    ? _g.__mvtkInteractiveExportSourcePath : "");
            if (!mapFileName) {
                reportExportFailure("Save the map first.");
                return;
            }
            if (map.modified) {
                reportExportFailure(
                    "Save the map before exporting. The exporter reads the saved TMX " +
                    "from disk so an old editor tab cannot overwrite newer project data."
                );
                return;
            }
            var dirtyTileset = unsavedTilesetName(map);
            if (dirtyTileset) {
                reportExportFailure(
                    "Save the referenced tileset before exporting:\n  " + dirtyTileset +
                    "\n\nThe exporter only packages saved TSX data."
                );
                return;
            }

            var root = detectProjectRoot();
            if (!_g.__mvtkWorldContext && _g.MVTKWorldExport) _g.MVTKWorldExport.recover(root);
            if (!root) {
                var setupCommand = (tiled.platform === "windows")
                    ? "tools\\set_tiled_export_path.bat"
                    : "sh ./tools/set_tiled_export_path.sh";
                reportExportFailure(
                    "Open your toolkit's Tiled project first.\n\n" +
                    "Choose File > Open File or Project... and pick MVTK.tiled-project in the\n" +
                    "toolkit folder (the folder that holds game.project). If Tiled shows a yellow bar\n" +
                    "about scripted extensions, click Enable Extensions. Exports then go to\n" +
                    "that toolkit.\n\n" +
                    "To export rooms without opening that project, run this once from the\n" +
                    "toolkit folder, then restart Tiled:\n" +
                    "  " + setupCommand
                );
                return;
            }

            var sourceMapPath = normalizedAbsoluteSourcePath(mapFileName, root);
            var sourceError = externalAuthoringError(sourceMapPath, root);
            if (sourceError) { reportExportFailure(sourceError); return; }
            var outDir = root + "/developer/assets/tiled/maps";
            var isExternalMap = pathKey(dirname(sourceMapPath)) !== pathKey(outDir);
            var room = basenameNoExt(sourceMapPath);
            var luaPath = outDir + "/" + room + ".lua";
            var tilemapPath = outDir + "/" + room + ".tilemap";
            var tmxPath = outDir + "/" + room + ".tmx";

            // Interactive and batch exports both require external originals.
            if (isExternalMap) {
                if (!/^[A-Za-z0-9_][A-Za-z0-9_-]*$/.test(room)) {
                    reportExportFailure(
                        "Rename the map file to letters/digits/underscores (got '" + room +
                        "') — the name becomes the Defold room id."
                    );
                    return;
                }
                var overwriteError = externalMapOverwriteError(
                    tmxPath, room, sourceMapPath, root
                );
                if (overwriteError) {
                    reportExportFailure(overwriteError);
                    return;
                }
            }

            var diskRead = readSavedMap(sourceMapPath);
            if (diskRead.error) {
                reportExportFailure(diskRead.error);
                return;
            }
            map = diskRead.map;

            if (typeof MVTKRelationships === "undefined") {
                reportExportFailure("Relationship extension is unavailable. Restart Tiled after updating the toolkit extensions.");
                return;
            }
            var relationshipRegistry = null, relationshipFresh = false;
            if (_g.__mvtkWorldContext) {
                // The world run built one registry for every member; per-room freshness is moot.
                relationshipRegistry = _g.__mvtkWorldContext.registry;
                relationshipFresh = true;
            } else {
                try { relationshipRegistry = JSON.parse(readTextFile(root + "/developer/assets/tiled/content_index.json")); }
                catch (indexError) { /* Local checks still run; cross-room checks are explicitly unverified. */ }
                var relationshipFiles = File.directoryEntries(outDir, File.Files);
                relationshipFresh = MVTKRelationships.fresh(relationshipRegistry, room, function(path) {
                    try { return readTextFile(root + "/" + path); } catch (e) { return null; }
                }, relationshipFiles);
            }
            var relationshipRecords = MVTKRelationships.collect(map, room,
                typeof MVTK_GROUPED_PROPERTY_SCHEMA === "undefined" ? null : MVTK_GROUPED_PROPERTY_SCHEMA);
            var relationshipOriginals = relationshipRecords.map(function(record) { return record.native.properties(); });
            var relationshipDiagnostics = MVTKRelationships.normalize(relationshipRecords);
            relationshipDiagnostics = relationshipDiagnostics.concat(
                MVTKRelationships.validate(relationshipRecords, relationshipRegistry, relationshipFresh, room));
            var relationshipMessages = relationshipDiagnostics.map(MVTKRelationships.format);
            relationshipMessages.forEach(function(message) { tiled.log("[MVTK] " + message); });
            if (_g) _g.__mvtkLastRelationshipDiagnostics = relationshipDiagnostics;
            if (relationshipDiagnostics.some(function(d) { return d.severity === "error"; })) {
                if (tiled.activeAsset && tiled.activeAsset.isTileMap &&
                    pathKey(tiled.activeAsset.fileName) === pathKey(sourceMapPath)) {
                    MVTKRelationships.select(tiled.activeAsset, relationshipDiagnostics, room);
                }
                reportExportFailure("Authored relationships block export. Previous outputs were kept.\n\n" +
                    relationshipMessages.join("\n") + "\n\nObjects in the open map have been selected. For other rooms, open the reported TMX and select its object ID.");
                return;
            }


            var luaFormat = findFormatById(["lua"]) || findFormatByExtension("lua") || findFormatByNameSubstring("lua");
            var defoldFormat = findFormatById(["defold", "Defold"]) || findFormatByExtension("tilemap") || findFormatByNameSubstring("defold");

            if (!luaFormat || !defoldFormat) {
                reportExportFailure(
                    "Required exporters not found.\n\n" +
                    "Turn on Tiled's defold and lua plugins: choose Edit > Preferences..., " +
                    "click the Plugins tab, tick defold and lua (defold.dll and lua.dll on Windows, " +
                    "libdefold.so and liblua.so on Linux), close the window and export again.\n\n" +
                    "Lua: " + (!!luaFormat) + "\n" +
                    "Defold: " + (!!defoldFormat) + "\n\n" +
                    "Available formats:\n" + listFormatNames()
                );
                return;
            }

            luaStagePath = outDir + "/." + room + ".mvtk_stage.lua";
            tilemapStagePath = outDir + "/." + room + ".mvtk_stage.tilemap";
            tmxStagePath = isExternalMap
                ? outDir + "/." + room + ".mvtk_stage.tmx"
                : "";
            removeFileIfPresent(luaStagePath);
            removeFileIfPresent(tilemapStagePath);
            removeFileIfPresent(tmxStagePath);

            // Localize every referenced tileset and image layer before touching
            // final room outputs. The shared asset transaction is rolled back
            // if any subsequent export, relink, TMX, or publish step fails.
            assets = copyTilesetAssets(map, root, relationshipRecords);
            if (assets.failed.length > 0) {
                var assetFailure =
                    "Export did not complete because project-local assets could not be prepared:\n  " +
                    assets.failed.join("\n  ") +
                    "\n\nFix these paths and export again before running Import Assets.";
                tiled.log("[MVTK] Asset localization failures: " + assets.failed.join(" | "));
                removeFileIfPresent(luaStagePath);
                removeFileIfPresent(tilemapStagePath);
                removeFileIfPresent(tmxStagePath);
                reportExportFailure(assetFailure);
                return;
            }
            if (_g && _g.__mvtkFailAfterAssetLocalization) {
                removeFileIfPresent(luaStagePath);
                removeFileIfPresent(tilemapStagePath);
                removeFileIfPresent(tmxStagePath);
                reportExportFailure(appendAssetRollbackErrors(
                    "Injected regression failure after asset localization.", assets
                ));
                return;
            }

            MVTKRelationships.apply(relationshipRecords);
            var err = writeWithFormat(luaFormat, map, luaStagePath, "Lua");
            // Keep native references in source/localized TMX; only Lua receives strings.
            relationshipRecords.forEach(function(record, index) { record.native.setProperties(relationshipOriginals[index]); });
            if (err) {
                removeFileIfPresent(luaStagePath);
                removeFileIfPresent(tilemapStagePath);
                removeFileIfPresent(tmxStagePath);
                reportExportFailure(appendAssetRollbackErrors(err, assets));
                return;
            }
            var collisionExport = { captures: [], injectedTiles: 0, error: "" };
            try {
                collisionExport = injectTileCollisionObjectGroups(luaStagePath, map);
            } catch (injectErr) {
                collisionExport.error = String(injectErr);
                tiled.log("[MVTK] Per-tile collision Lua injection failed: " + injectErr);
            }

            err = writeWithFormat(defoldFormat, map, tilemapStagePath, "Defold tilemap");
            if (err) {
                removeFileIfPresent(luaStagePath);
                removeFileIfPresent(tilemapStagePath);
                removeFileIfPresent(tmxStagePath);
                reportExportFailure(appendAssetRollbackErrors(err, assets));
                return;
            }
            postProcessDefoldTilemapDepth(tilemapStagePath);

            var luaRelink = relinkExportedLuaTilesetPaths(luaStagePath, assets);
            if (luaRelink.error) {
                removeFileIfPresent(luaStagePath);
                removeFileIfPresent(tilemapStagePath);
                removeFileIfPresent(tmxStagePath);
                reportExportFailure(appendAssetRollbackErrors(
                    "Lua tileset relink failed:\n" + luaRelink.error, assets
                ));
                return;
            }
            if (luaRelink.count > 0) {
                tiled.log("[MVTK] Relinked " + luaRelink.count +
                    " Lua tileset reference(s) to project-local TSX files");
            }

            var tilesetImageRelink = relinkExportedLuaTilesetImagePaths(
                luaStagePath, assets
            );
            if (tilesetImageRelink.error) {
                removeFileIfPresent(luaStagePath);
                removeFileIfPresent(tilemapStagePath);
                removeFileIfPresent(tmxStagePath);
                reportExportFailure(appendAssetRollbackErrors(
                    "Lua tileset-image relink failed:\n" +
                        tilesetImageRelink.error, assets
                ));
                return;
            }
            if (tilesetImageRelink.count > 0) {
                tiled.log("[MVTK] Relinked " + tilesetImageRelink.count +
                    " Lua tileset image reference(s) to project-local tilesheets");
            }

            var imageRelink = relinkExportedLuaImageLayerPaths(luaStagePath, assets);
            if (imageRelink.error) {
                removeFileIfPresent(luaStagePath);
                removeFileIfPresent(tilemapStagePath);
                removeFileIfPresent(tmxStagePath);
                reportExportFailure(appendAssetRollbackErrors(
                    "Lua image-layer relink failed:\n" + imageRelink.error, assets
                ));
                return;
            }
            if (imageRelink.count > 0) {
                tiled.log("[MVTK] Relinked " + imageRelink.count +
                    " Lua image-layer reference(s) to project-local backgrounds");
            }

            var musicRelink = relinkExportedLuaMusicPath(luaStagePath, assets);
            if (musicRelink.error) {
                removeFileIfPresent(luaStagePath);
                removeFileIfPresent(tilemapStagePath);
                removeFileIfPresent(tmxStagePath);
                reportExportFailure(appendAssetRollbackErrors(
                    "Lua room-music relink failed:\n" + musicRelink.error, assets
                ));
                return;
            }
            if (musicRelink.count > 0) {
                tiled.log("[MVTK] Relinked room music to the project-local music file");
            }
            var enemyRelink = relinkExportedLuaEnemyArt(luaStagePath, assets);
            if (enemyRelink.error) {
                removeFileIfPresent(luaStagePath);
                removeFileIfPresent(tilemapStagePath);
                removeFileIfPresent(tmxStagePath);
                reportExportFailure(appendAssetRollbackErrors(
                    "Lua enemy-art relink failed:\n" + enemyRelink.error, assets
                ));
                return;
            }

            var localizedTmx = { count: 0, externalTemplates: [], error: "" };
            if (isExternalMap) {
                localizedTmx = publishLocalizedTmx(
                    map, sourceMapPath, tmxStagePath, root, assets
                );
                if (localizedTmx.error) {
                    removeFileIfPresent(luaStagePath);
                    removeFileIfPresent(tilemapStagePath);
                    removeFileIfPresent(tmxStagePath);
                    reportExportFailure(appendAssetRollbackErrors(
                        "Localized project TMX failed:\n" + localizedTmx.error, assets
                    ));
                    return;
                }
            }

            // Record the original TMX and its transitive TSX/template/art sources.
            // Missing sources stay explicit unknowns in Defold's status report.
            var provenanceEntries = [], provenanceSeen = {};
            function sourceDependency(path, stagedPath, imported) {
                path = cleanPath(path);
                if (provenanceSeen[path]) return;
                provenanceSeen[path] = true;
                var binary = !/\.(tmx|tsx|tx)$/i.test(path), signature = "unavailable", sourceText = "";
                try {
                    if (binary) {
                        signature = fileFingerprint(stagedPath || path);
                    } else {
                        var textResult = textFingerprint(stagedPath || path);
                        sourceText = textResult.text; signature = textResult.signature;
                    }
                } catch (dependencyError) { /* explicit unavailable fingerprint */ }
                var portable = path.indexOf(cleanPath(root) + "/") === 0 ? path.slice(cleanPath(root).length + 1) : path;
                if (imported && (portable === path || signature === "unavailable")) {
                    throw new Error("Imported input must exist inside the Defold project: " + path);
                }
                provenanceEntries.push("{path=" + JSON.stringify(portable) + ",binary=" + binary + ",fingerprint=" + JSON.stringify(signature) + "}");
                if (!binary) {
                    var refs = /\b(?:source|template)="([^"]+)"/g, match;
                    while ((match = refs.exec(sourceText)) !== null) sourceDependency(resolvePath(dirname(path), match[1].replace(/&amp;/g, "&")), null, imported);
                    var fileProps = /<property\b[^>]*type="file"[^>]*value="([^"]+)"/g;
                    while ((match = fileProps.exec(sourceText)) !== null) if (match[1]) sourceDependency(resolvePath(dirname(path),match[1].replace(/&amp;/g,"&")), null, imported);
                }
            }
            sourceDependency(sourceMapPath);
            var linkedEnemyArt = assets.enemyArt;
            if (linkedEnemyArt) linkedEnemyArt.sourceFiles.forEach(function (path) { sourceDependency(path); });
            var originalEntries = provenanceEntries;
            provenanceEntries = []; provenanceSeen = {};
            // Record the localized graph, including the staged TMX's final
            // destination. Defold consumes this snapshot without opening originals.
            sourceDependency(tmxPath, isExternalMap ? tmxStagePath : sourceMapPath, true);
            if (linkedEnemyArt) linkedEnemyArt.localFiles.forEach(function (path) { sourceDependency(path, null, true); });
            // Tie the Lua export to the exact saved TMX that produced it.
            var relationshipSourceText = readTextFile(isExternalMap ? tmxStagePath : sourceMapPath);
            var relationshipSignature = MVTKRelationships.fingerprint(relationshipSourceText);
            var relationshipLua = readTextFile(luaStagePath);
            relationshipLua = relationshipLua.replace(/return\s*\{/, "return {\n  mvtk_source_signature = \"" + relationshipSignature + "\",");
            relationshipLua = relationshipLua.replace(/return\s*\{/, "return {\n  mvtk_provenance = {version=2, source=" + JSON.stringify(sourceMapPath) + ", dependencies={" + provenanceEntries.join(",") + "}, sources={" + originalEntries.join(",") + "}},");
            writeTextFile(luaStagePath, relationshipLua);

            var publishPairs = [
                { stagedPath: luaStagePath, finalPath: luaPath },
                { stagedPath: tilemapStagePath, finalPath: tilemapPath }
            ];
            if (isExternalMap) {
                publishPairs.push({ stagedPath: tmxStagePath, finalPath: tmxPath });
            }
            var publishError;
            var receiptError = recordSourceCopy(sourceMapPath, tmxPath, assets.transaction, tmxStagePath);
            if (receiptError) throw new Error(receiptError);
            if (_g.__mvtkWorldContext) {
                _g.__mvtkWorldContext.pairs = _g.__mvtkWorldContext.pairs.concat(publishPairs);
                publishError = null;
            } else publishError = publishStagedOutputs(publishPairs);
            if (publishError) {
                removeFileIfPresent(luaStagePath);
                removeFileIfPresent(tilemapStagePath);
                removeFileIfPresent(tmxStagePath);
                reportExportFailure(appendAssetRollbackErrors(
                    "Could not publish the exported room outputs:\n" + publishError, assets
                ));
                return;
            }
            promoteLocalizedAssets(assets);
            commitTilesetAssets(assets);
            luaStagePath = "";
            tilemapStagePath = "";
            tmxStagePath = "";

            tiled.log("[MVTK] Exported Lua + Defold Tilemap" +
                (isExternalMap ? " + localized TMX" : "") + " for '" + room + "'");
            var summary = "Export complete:\n" + luaPath + "\n" + tilemapPath;
            if (relationshipMessages.length) summary += "\n\nRelationship checks:\n" + relationshipMessages.join("\n");
            if (isExternalMap) {
                summary += "\n" + tmxPath +
                    "\n\nGenerated project map copy:\n  " + tmxPath +
                    "\nKeep authoring your original at:\n  " + sourceMapPath +
                    "\nRe-export from Tiled to update the generated project copy.";
            }
            if (collisionExport.injectedTiles > 0) {
                tiled.log("[MVTK] Embedded per-tile collision for " +
                    collisionExport.injectedTiles + " tile(s) into " + luaPath);
            }
            if (collisionExport.error) {
                summary += "\n\n⚠ Could not embed per-tile collision into the Lua export:\n  " +
                    collisionExport.error;
            }
            if (assets.copied.length > 0) {
                summary += "\n\nCopied tileset/image assets:\n  " + assets.copied.join("\n  ");
            }
            if (assets.skippedCollections.length > 0) {
                summary += "\n\nNote: collection tileset(s) had no per-tile images to copy:\n  " +
                    assets.skippedCollections.join("\n  ") +
                    "\nAdd images to the tileset's tiles, or these tilesets will not import.";
            }
            // Surface both a completed localization and recognized references
            // that could not be localized (unsupported or missing).
            var roomMusic = assets.music || collectRoomMusic(map, root);
            if (roomMusic.file) {
                summary += roomMusic.relinked
                    ? "\n\nLocalized room music:\n  " + roomMusic.file
                    : "\n\nRoom music:\n  " + roomMusic.file;
                tiled.log("[MVTK] Room music: " + roomMusic.file);
            }
            if (roomMusic.warnings.length > 0) {
                summary += "\n\n⚠ Room music:\n  - " + roomMusic.warnings.join("\n  - ");
                tiled.log("[MVTK] Room music warnings: " + roomMusic.warnings.join(" | "));
            }
            if (linkedEnemyArt && linkedEnemyArt.copied.length) {
                summary += "\n\nLocalized enemy art:\n  " + linkedEnemyArt.copied.join("\n  ");
            }
            if (linkedEnemyArt && linkedEnemyArt.warnings.length) {
                summary += "\n\n⚠ Enemy art:\n  - " + linkedEnemyArt.warnings.join("\n  - ");
                tiled.log("[MVTK] Enemy art warnings: " + linkedEnemyArt.warnings.join(" | "));
            }

            var paintedSets = tilesetsPaintedOnTileLayers(map);
            var collisionWarnings = collectPerTileCollisionWarnings(collisionExport.captures, assets, paintedSets);
            if (collisionWarnings.length > 0) {
                summary += "\n\n⚠ Check per-tile collision:\n  - " + collisionWarnings.join("\n  - ");
                tiled.log("[MVTK] Per-tile collision warnings: " + collisionWarnings.join(" | "));
            }
            var multiSheet = collectMultipleTilesheetWarnings(map, paintedSets);
            if (multiSheet.length > 0) {
                summary += "\n\n⚠ Multiple tilesheets on tile layers:\n  - " + multiSheet.join("\n  - ");
                tiled.log("[MVTK] Multiple-tilesheet warnings: " + multiSheet.join(" | "));
            }
            if (localizedTmx.externalTemplates.length > 0) {
                summary += "\n\n⚠ This map uses template files outside the toolkit:\n  " +
                    localizedTmx.externalTemplates.join("\n  ") +
                    "\nUse the toolkit's templates from tiled/templates/ or the objects may not bake correctly.";
                tiled.log("[MVTK] External template warnings: " +
                    localizedTmx.externalTemplates.join(" | "));
            }

            // If this map's tile size differs from the project's configured size,
            // offer to update tile_settings.lua to match -- rather than only
            // warning and leaving the room to import at the wrong scale. On
            // success collectAuthoringWarnings (below) re-reads the file and the
            // mismatch warning drops out automatically; if declined it remains.
            if ((!_g || !_g.__mvtkBatchExportQuiet) && typeof tiled.confirm === "function") {
                var projSize = readProjectTileSize(root);
                if (projSize && (projSize.width !== map.tileWidth || projSize.height !== map.tileHeight)) {
                    var mapTW = map.tileWidth, mapTH = map.tileHeight;
                    var doUpdate = tiled.confirm(
                        "This map's tile size is " + mapTW + "x" + mapTH + ", but the " +
                        "project (developer/config/tile_settings.lua) is " +
                        projSize.width + "x" + projSize.height + ".\n\n" +
                        "Update the project tile size to " + mapTW + "x" + mapTH +
                        " to match this map?\n\n" +
                        "This rewrites tile_settings.lua. Re-run Create Rooms in " +
                        "Defold afterward so rooms import at the matching scale.",
                        "Update project tile size?"
                    );
                    if (doUpdate) {
                        var upErr = writeProjectTileSize(root, mapTW, mapTH);
                        if (upErr) {
                            summary += "\n\n⚠ Could not update tile_settings.lua:\n  " + upErr;
                            tiled.log("[MVTK] tile_settings.lua update failed: " + upErr);
                        } else {
                            summary += "\n\n✔ Updated project tile size to " + mapTW + "x" +
                                mapTH + " in developer/config/tile_settings.lua.\n" +
                                "Re-run Create Rooms in Defold so rooms import at the new scale.";
                            tiled.log("[MVTK] Updated tile_settings.lua to " + mapTW + "x" + mapTH);
                        }
                    }
                }
            }

            // Non-blocking authoring checks (missing templates layer, tile-size
            // mismatches). The export still wrote successfully; these are things
            // to fix before Create Rooms so the room is not silently "off".
            var authoring = collectAuthoringWarnings(map, root);
            if (authoring.length > 0) {
                summary += "\n\n⚠ Check before building:\n  - " + authoring.join("\n  - ");
                tiled.log("[MVTK] Authoring warnings: " + authoring.join(" | "));
            }
            if (_g) _g.__mvtkLastExportSummary = summary;
            alertUser(summary);
        } catch (e) {
            removeFileIfPresent(luaStagePath);
            removeFileIfPresent(tilemapStagePath);
            removeFileIfPresent(tmxStagePath);
            reportExportFailure(appendAssetRollbackErrors(
                "Export action crashed:\n" + e, assets
            ));
        } finally {
            endFingerprintMemo(memoOwned);
        }
    });

    action.text = "Export Current Room";
    _g.MVTKMapExport = {
        version: apiVersion,
        fingerprint: fileFingerprint, beginMemo: beginFingerprintMemo, endMemo: endFingerprintMemo,
        fingerprintStats: function() { return fingerprintStats; },
        root: detectProjectRoot, projectRoot: openProjectRoot, read: readTextFile, write: writeTextFile,
        readMap: readSavedMap, exists: fileExists, copy: copyOne,
        mkdir: ensureDir, remove: removeFileIfPresent, publish: publishStagedOutputs,
        absolute: normalizedAbsoluteSourcePath, dirname: dirname, key: pathKey,
        tileSize: readProjectTileSize, writeTileSize: writeProjectTileSize,
        overwriteError: externalMapOverwriteError,
        sourceError: externalAuthoringError, insideRoot: authoringPathIsInsideRoot
    };

    // Re-registering an action replaces its QAction, removing the old menu
    // entry. Attach the replacement too. The API-version guard above prevents
    // duplicate registration when global and project copies are both current.
    // --evaluate has no menus; the export action remains callable headlessly.
    if (tiled.menus.indexOf("File") >= 0) tiled.extendMenu("File", [
        { separator: true },
        { action: "MVTK.ExportLuaAndDefold" }
    ]);
    _g.__mvtkExportLuaAndDefoldLoaded = true;
})();
