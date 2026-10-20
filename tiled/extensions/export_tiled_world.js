/* One world generation, using the existing paired map exporter. Tiled 1.11+. */
(function () {
    var g = typeof globalThis !== "undefined" ? globalThis : this;
    if (g.__mvtkWorldExportLoaded >= 7) return;
    g.__mvtkWorldExportLoaded=7;
    function api() {
        if (!g.MVTKMapExport) throw new Error(
            "The paired map exporter did not initialize. Open MVTK.tiled-project " +
            "with project extensions enabled, then check the Tiled Console for " +
            "errors loading tiled/extensions/export_lua_and_defold.js."
        );
        return g.MVTKMapExport;
    }
    function check(value, message) { if (!value) throw new Error(message); }
    // Read saved JSON: enum values are serialized strings, whereas the scripting
    // API wraps them in PropertyValue objects with numeric enum indices.
    function worldProperties(data) {
        var supported={world_name:"string",default_biome:"string",default_music:"string",
            default_ambience:"string",default_map_color:"color"}, result={};
        (data.properties || []).forEach(function(p) {
            if (!supported[p.name]) return;
            check(result[p.name]===undefined,"Duplicate world property: "+p.name);
            check(typeof p.value==="string" && (!p.type || p.type===supported[p.name] ||
                (p.name==="default_map_color" && p.type==="string")),
                "World property "+p.name+" must use type "+supported[p.name]+".");
            if(p.name==="default_map_color") check(p.value==="" || /^#(?:[0-9a-f]{6}|[0-9a-f]{8})$/i.test(p.value),
                "default_map_color must be a Color (#RRGGBB or #AARRGGBB).");
            result[p.name]=p.value;
        });
        return result;
    }
    function initializeWorld(world) {
        var fields=["world_name","default_biome","default_music","default_ambience","default_map_color"];
        if(world.readOnly || fields.every(function(name){return world.property(name)!==undefined;})) return;
        world.macro("Add Microvania world properties",function() {
            function add(name,value) { if(world.property(name)===undefined) world.setProperty(name,value); }
            add("world_name","");
            add("default_biome",tiled.propertyValue("biomes","inherit"));
            add("default_music",tiled.propertyValue("music_tracks","inherit"));
            add("default_ambience",tiled.propertyValue("ambient_sounds","none"));
            add("default_map_color",tiled.color("#00000000"));
        });
    }
    var seenWorlds=[], initializing=false;
    function initializeOpenWorlds() {
        // Global extension copies must not modify worlds in unrelated projects.
        if(initializing || !/(^|[\\/])MVTK\.tiled-project$/i.test(tiled.projectFilePath || "")) return;
        var worlds=tiled.worlds || [];
        seenWorlds=seenWorlds.filter(function(world){return worlds.indexOf(world)>=0;});
        initializing=true;
        try {
            worlds.forEach(function(world) {
                if(seenWorlds.indexOf(world)>=0 || world.readOnly) return;
                // Mark before mutation: worldsChanged also fires for property edits.
                // Observe once per load so Undo/removing a field is not fought.
                seenWorlds.push(world);
                try {initializeWorld(world);} catch(e) {tiled.error("Could not initialize world properties: "+e);}
            });
        } finally {initializing=false;}
    }
    function lua(v) {
        if (v === null || v === undefined) return "nil";
        if (typeof v === "string") return '"' + v.replace(/[\\"\x00-\x1f]/g, function(c) {
            return c === '"' || c === '\\' ? '\\' + c : '\\' + ('00' + c.charCodeAt(0)).slice(-3);
        }) + '"';
        if (typeof v !== "object") return String(v);
        if (Array.isArray(v)) return "{" + v.map(lua).join(",") + "}";
        return "{" + Object.keys(v).sort().map(function(k) { return "[" + lua(k) + "]=" + lua(v[k]); }).join(",") + "}";
    }
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
    function fingerprint(path, bypassMemo) {
        var a = api();
        // Older map exporters have no shared memo; the local helper is equivalent.
        if (a.fingerprint) return a.fingerprint(path, bypassMemo);
        var f = new BinaryFile(path, BinaryFile.ReadOnly), bytes = new Uint8Array(f.readAll()); f.close();
        return adlerBytes(bytes);
    }
    function journalPath(root) { return root + "/developer/assets/tiled/.world_export_transaction.json"; }
    function recover(root) {
        var a=api(), path=journalPath(root); if (!a.exists(path)) return;
        var journal=JSON.parse(a.read(path)), prefix=a.key(root + "/developer")+"/";
        check(journal.version===1 && Array.isArray(journal.files), "Invalid world recovery journal: " + path);
        journal.files.forEach(function(f) {
            check(a.key(f.path).indexOf(prefix)===0 && !/(^|\/)\.\.(\/|$)/.test(f.path) &&
                f.backup===f.path+".mvtk_world_backup", "Unsafe world recovery path");
        });
        (journal.staged || []).forEach(function(path){
            check(a.key(path).indexOf(prefix)===0 && !/(^|\/)\.\.(\/|$)/.test(path) &&
                (/\/\.[^/]+\.mvtk_stage\.(lua|tmx|tilemap)$/.test(path) || /\.mvtk_(asset_backup|backup)$/.test(path)),"Unsafe world staging recovery path");
        });
        if (!journal.committed) journal.files.slice().reverse().forEach(function(f) {
            if (f.existed) { check(a.exists(f.backup), "Missing world recovery backup: " + f.backup); check(!a.copy(f.backup,f.path,true), "Failed to restore " + f.path); }
            else { a.remove(f.path); check(!a.exists(f.path), "Failed to remove " + f.path); }
        });
        journal.files.forEach(function(f) { a.remove(f.backup); });
        (journal.staged || []).forEach(function(path){a.remove(path);});
        a.remove(path); check(!a.exists(path), "Could not clear world recovery journal");
    }
    function begin(root) {
        var a=api(), journal={version:1,files:[],staged:[]}, touched={}, assets={}, suspended=false;
        var context={pairs:[],registry:null,localized:{}};
        function persist() { a.write(journalPath(root),JSON.stringify(journal)); }
        context.beforeWrite=function(path) {
            var key=a.key(path), prefix=a.key(root+"/developer")+"/";
            if (suspended || key.indexOf(prefix)!==0 || /\.mvtk_(?:stage\.|world_backup$)/.test(path) || /\.world_export_transaction\.json$/.test(path)) return;
            if (touched[key]) return;
            suspended=true;
            try {
                if(/\.mvtk_(asset_backup|backup)$/.test(path)) {
                    journal.staged.push(path);persist();touched[key]=true;return;
                }
                var rec={path:path,backup:path+".mvtk_world_backup",existed:a.exists(path)};
                if (rec.existed) check(!a.copy(path,rec.backup,true), "Could not back up " + path);
                journal.files.push(rec); persist(); touched[key]=true;
            } finally { suspended=false; }
        };
        context.asset=function(src,dst) {
            var key=a.key(dst), source=a.key(src);
            check(!assets[key] || assets[key]===source, "Two world assets target the same file: " + dst);
            assets[key]=source;
        };
        context.commit=function() { journal.committed=true; persist(); };
        context.stage=function(path) { journal.staged.push(path);persist(); };
        persist(); return context;
    }
    function save(asset) {
        check(asset.fileName, "Save every world member before exporting.");
        if (asset.modified) check(asset.save() && !asset.modified, "Save canceled or failed: " + asset.fileName);
    }
    function chooseWorld() {
        if(g.__mvtkWorldExportWorld) return g.__mvtkWorldExportWorld;
        var worlds=tiled.worlds || [], active=tiled.activeAsset;
        var choices=worlds.filter(function(w) { return active && active.isTileMap && w.containsMap(active); });
        if (!choices.length) choices=worlds;
        check(choices.length, "Open a .world file in Tiled, then export again.");
        if (choices.length===1) return choices[0];
        var answer=tiled.prompt("Select the world number:\n"+choices.map(function(w,i){ return (i+1)+". "+w.fileName; }).join("\n"),"1","Export All Maps and Tiled World");
        if (!answer) return null;
        var index=Number(answer)-1; check(Number.isInteger(index) && choices[index],"Choose a listed world number.");
        return choices[index];
    }
    function run(world) {
        var a=api(), memoOwned=a.beginMemo ? a.beginMemo() : false;
        try { return runWorld(world); }
        finally { if(a.endMemo) a.endMemo(memoOwned); }
    }
    function runWorld(world) {
        var a=api(), root=a.root(); check(root,"Set the toolkit export path first."); recover(root);
        check(!a.insideRoot(a.absolute(world.fileName,root),root),
            "Save the original Tiled world outside the Defold project before exporting.");
        world.allMaps().forEach(function(entry){
            var error=a.sourceError(a.absolute(entry.fileName,root),root);check(!error,error);
        });
        // Save member tabs and standalone referenced TSX tabs before saving the
        // world: resizing a map can also dirty its containing world's rectangle.
        world.allMaps().forEach(function(entry){
            var path=a.absolute(entry.fileName,root);
            (tiled.openAssets || []).forEach(function(asset){if(a.key(asset.fileName || "")===a.key(path)) save(asset);});
            var disk=a.readMap(path);check(!disk.error,disk.error);
            (disk.map.tilesets || []).forEach(function(ts){
                if(!ts.fileName)return; // Embedded tilesets are saved with their map.
                (tiled.openAssets || []).forEach(function(asset){if(asset.isTileset && a.key(asset.fileName || "")===a.key(ts.fileName)) save(asset);});
            });
        });
        save(world);
        // Re-read the saved world so external edits cannot be fingerprinted as
        // fresh while exporting positions retained in an older editor session.
        if (!g.__mvtkWorldExportWorld) {
            var savedWorld=world.fileName;
            tiled.unloadWorld(savedWorld);tiled.loadWorld(savedWorld);
            world=(tiled.worlds || []).filter(function(w){return a.key(w.fileName)===a.key(savedWorld);})[0];
            check(world,"Could not reload the saved world: "+savedWorld);
        }
        var entries=world.allMaps(); check(entries.length,"The world contains no maps.");
        var source=a.absolute(world.fileName,root), ids={}, maps=[], starts=[], tw,th,dependencies={},worldFingerprint=fingerprint(source);
        var worldSettings=worldProperties(JSON.parse(a.read(source)));
        function capture(path) {
            path=a.absolute(path,root);if(dependencies[path]!==undefined)return;
            check(a.exists(path),"World source dependency is missing: "+path);
            dependencies[path]=fingerprint(path);
            if(/\.(?:tmx|tsx|tx)$/i.test(path)) {
                var xml=a.read(path),match,refs=/\b(?:source|template)="([^"]+)"/g;
                while((match=refs.exec(xml))!==null) capture(a.absolute(match[1].replace(/&amp;/g,"&"),a.dirname(path)));
                var props=/<property\b[^>]*type="file"[^>]*value="([^"]+)"/g;
                while((match=props.exec(xml))!==null) if(match[1]) capture(a.absolute(match[1].replace(/&amp;/g,"&"),a.dirname(path)));
            }
        }
        capture(source);capture(root+"/MVTK.tiled-project");capture(root+"/developer/config/tile_settings.lua");
        var registry={version:2,objects:[],sources:{},configs:{}};
        // Reuse config domains only when their recorded disk sources still match.
        try {
            var old=JSON.parse(a.read(root+"/developer/assets/tiled/content_index.json")), valid=true;
            Object.keys(old.sources || {}).forEach(function(p) { if (p.indexOf("developer/config/")===0) {
                capture(root+"/"+p);if(MVTKRelationships.fingerprint(a.read(root+"/"+p))!==old.sources[p]) valid=false;
            } });
            if(valid) { registry.configs=old.configs; registry.completion=old.completion; }
        } catch(ignore) { /* Defold preparation validates current config domains. */ }
        entries.forEach(function(entry) {
            var path=a.absolute(entry.fileName,root), id=path.replace(/\\/g,"/").split("/").pop().replace(/\.[^.]+$/,"");
            check(/\.tmx$/i.test(path),"Save world members as TMX maps for paired Defold export: "+path);
            check(/^[A-Za-z0-9_][A-Za-z0-9_-]*$/.test(id),"Invalid room filename: "+path);
            check(!ids[id.toLowerCase()],"Duplicate room filename/placement: "+id); ids[id.toLowerCase()]=true;
            (tiled.openAssets || []).forEach(function(asset) {
                if(a.key(asset.fileName || "")===a.key(path)) {
                    save(asset); (asset.tilesets || []).forEach(function(ts){if(ts.fileName)save(ts);});
                }
            });
            capture(path);
            var disk=a.readMap(path); check(!disk.error,disk.error); var map=disk.map;
            check(!map.infinite && map.orientation===TileMap.Orthogonal,"World export requires finite orthogonal maps: "+id);
            var r=entry.rect, w=map.width*map.tileWidth,h=map.height*map.tileHeight;
            check(r.width===w && r.height===h,"World rectangle does not match saved map dimensions: "+id+". Refresh the world in Tiled.");
            if(!tw) {tw=map.tileWidth;th=map.tileHeight;}
            check(tw===map.tileWidth && th===map.tileHeight,"World maps must use the same tile dimensions: "+id);
            check(Number.isFinite(r.x) && Number.isFinite(r.y),"Invalid world position: "+id);
            var localPath=root+"/developer/assets/tiled/maps/"+id+".tmx";
            if(a.key(path)!==a.key(localPath)) check(!a.overwriteError(localPath,id,path,root),"Export would replace an unrelated project map: "+id);
            var records=MVTKRelationships.collect(map,id,typeof MVTK_GROUPED_PROPERTY_SCHEMA==="undefined" ? null : MVTK_GROUPED_PROPERTY_SCHEMA);
            var diagnostics=MVTKRelationships.normalize(records);
            check(!diagnostics.some(function(d){return d.severity==="error";}),diagnostics.map(MVTKRelationships.format).join("\n"));
            registry.objects=registry.objects.concat(records); registry.sources["developer/assets/tiled/maps/"+id+".lua"]="world";
            if(map.property("is_starting_room")===true) starts.push(id);
            maps.push({id:id,path:path,map:map,x:r.x,y:r.y,width:w,height:h});
        });
        check(starts.length===1,"Set is_starting_room on exactly one world map (found "+starts.length+").");
        var size=a.tileSize(root);
        check(size,"Could not read project tile dimensions from developer/config/tile_settings.lua.");
        var updateSize=size.width!==tw || size.height!==th;
        if(updateSize) {
            var warning="The exported maps use "+tw+"x"+th+" tiles, but the project uses "+size.width+"x"+size.height+".\n\n"+
                "Export will update the project tile dimensions to "+tw+"x"+th+" to match the maps.\n"+
                "After exporting, run Project > Prepare & Check in Defold to rebuild rooms at the new scale.";
            tiled.log("[MVTK] "+warning);
            if(!g.__mvtkWorldExportQuiet)tiled.alert(warning,"Project tile dimensions will change");
        }
        var context=begin(root); context.registry=registry; g.__mvtkWorldContext=context;
        var previous=[g.__mvtkBatchExportMap,g.__mvtkBatchExportSourcePath,g.__mvtkBatchExportQuiet];
        try {
            if(updateSize) {
                var settingsPath=a.absolute(root+"/developer/config/tile_settings.lua",root);
                check(fingerprint(settingsPath,true)===dependencies[settingsPath],"Source changed during world export: "+settingsPath+". Export again.");
                // The shared writer participates in this transaction, so failed
                // exports restore the settings along with the previous outputs.
                var sizeError=a.writeTileSize(root,tw,th);
                check(!sizeError,"Could not update project tile dimensions: "+sizeError);
                // Accept our own edit; still detect later changes during export.
                dependencies[settingsPath]=fingerprint(settingsPath);
            }
            maps.forEach(function(m,index) {
                var roomStarted=Date.now();
                ["lua","tilemap","tmx"].forEach(function(ext){context.stage(root+"/developer/assets/tiled/maps/."+m.id+".mvtk_stage."+ext);});
                g.__mvtkBatchExportMap=m.map;g.__mvtkBatchExportSourcePath=m.path;g.__mvtkBatchExportQuiet=true;
                tiled.trigger("MVTK.ExportLuaAndDefold");
                check(!g.__mvtkLastExportError,g.__mvtkLastExportError);
                tiled.log("[MVTK] World export "+(index+1)+"/"+maps.length+": "+m.id+" ("+(Date.now()-roomStarted)+" ms)");
                if(typeof g.__mvtkWorldAfterMap==="function") g.__mvtkWorldAfterMap(m,index);
                if(g.__mvtkWorldFailAfter===index+1) throw new Error("Injected world export failure");
            });
            Object.keys(dependencies).forEach(function(path){check(a.exists(path) && fingerprint(path,true)===dependencies[path],"Source changed during world export: "+path+". Export again.");});
            var manifest={version:1,input_mode:"project_copies",source:source,source_fingerprint:worldFingerprint,tile_width:tw,tile_height:th,start_room:starts[0],maps:[],dependencies:[]};
            manifest.world_properties=worldSettings;
            Object.keys(dependencies).sort().forEach(function(path){
                // Config edits need preparation, not a new Tiled export. They
                // are frozen during this batch but not owned by Tiled afterward.
                if(a.key(path).indexOf(a.key(root+"/developer/config/"))!==0)
                    manifest.dependencies.push({path:path,fingerprint:dependencies[path]});
            });
            if((world.patterns || []).length) {
                manifest.pattern_directory=a.dirname(source);
                manifest.pattern_files=File.directoryEntries(manifest.pattern_directory,File.Files).filter(function(p){return /\.tmx$/i.test(p);}).sort();
            }
            maps.forEach(function(m) {
                var rec={id:m.id,source:m.path,source_fingerprint:fingerprint(m.path),x:m.x,y:m.y,width:m.width,height:m.height};
                context.pairs.forEach(function(p){if(p.finalPath===root+"/developer/assets/tiled/maps/"+m.id+".lua") rec.lua_fingerprint=fingerprint(p.stagedPath);
                    if(p.finalPath===root+"/developer/assets/tiled/maps/"+m.id+".tilemap") rec.tilemap_fingerprint=fingerprint(p.stagedPath);});
                manifest.maps.push(rec);
            });
            var out=root+"/developer/assets/tiled/worlds";a.mkdir(out);
            var stage=out+"/.pending.mvtk_stage.lua", final=out+"/pending.lua";
            context.stage(stage);
            a.write(stage,"-- Generated by Export All Maps and Tiled World.\nreturn "+lua(manifest)+"\n");
            context.pairs.push({stagedPath:stage,finalPath:final});
            check(!a.publish(context.pairs),"Could not publish world outputs; previous generation will be restored.");
            context.commit(); g.__mvtkWorldContext=null; recover(root);
            return manifest;
        } catch(e) {
            g.__mvtkWorldContext=null;
            try {recover(root);} catch(recovery) {throw new Error(e+"\nRecovery pending: "+recovery);}
            throw e;
        } finally {
            g.__mvtkWorldContext=null;
            context.pairs.forEach(function(p){a.remove(p.stagedPath);});
            g.__mvtkBatchExportMap=previous[0];g.__mvtkBatchExportSourcePath=previous[1];g.__mvtkBatchExportQuiet=previous[2];
        }
    }
    g.MVTKWorldExport={run:run,recover:recover,worldProperties:worldProperties,initializeWorld:initializeWorld};
    if(tiled.worldsChanged) tiled.worldsChanged.connect(initializeOpenWorlds);
    if(tiled.activeAssetChanged) tiled.activeAssetChanged.connect(initializeOpenWorlds);
    initializeOpenWorlds();
    var action=tiled.registerAction("MVTK.ExportAllMapsAndTiledWorld",function() {
        g.__mvtkLastWorldExportError="";
        g.__mvtkLastWorldFingerprintStats="";
        try {var world=chooseWorld();if(!world)return;var started=Date.now(),result=run(world);
            var message="Exported "+result.maps.length+" maps and Tiled world in "+((Date.now()-started)/1000).toFixed(1)+" s.\n\nIn Defold: stop the game, then Project > Prepare & Check.\nSelect Use Tiled World Layout to use these placements.";
            tiled.log(message);
            if(api().fingerprintStats) {
                var stats=api().fingerprintStats();
                var hits=String(stats.hits).replace(/\B(?=(\d{3})+(?!\d))/g,",");
                g.__mvtkLastWorldFingerprintStats="[MVTK] Fingerprints: "+stats.files+" files, "+
                    (stats.bytes/1000000).toFixed(1)+" MB hashed in "+(stats.ms/1000).toFixed(1)+" s, "+hits+" memo hits.";
                tiled.log(g.__mvtkLastWorldFingerprintStats);
            }
            if(!g.__mvtkWorldExportQuiet)tiled.alert(message);
        } catch(e) {g.__mvtkLastWorldExportError=String(e);tiled.error(String(e));if(!g.__mvtkWorldExportQuiet)tiled.alert(String(e));}
    });
    action.text="Export All Maps and Tiled World";
    if (tiled.menus.indexOf("File") >= 0) tiled.extendMenu("File",[{action:"MVTK.ExportAllMapsAndTiledWorld"}]);
})();
