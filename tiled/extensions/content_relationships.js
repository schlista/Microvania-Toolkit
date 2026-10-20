/* Tiled-side checks use the last authoritative project index for cross-room
 * facts. Local object links never depend on that cache. Pure functions below
 * also run under Node for regressions; no extra interpreter is needed by Tiled.
 */
var MVTKRelationships = (function () {
    "use strict";
    var M = {};
    var aliases = {target_ref:"target_id", boss_ref:"boss_id", arena_ref:"arena_id"};
    var targets = {
        target_id:{timed_door:"door_id", hazard:"hazard_id", elevator:"elevator_id", teleporter:"teleporter_id"},
        boss_id:{boss:"boss_id"}, arena_id:{boss_arena:"arena_id"}
    };
    function text(v) { return v === undefined || v === null ? "" : String(v).trim(); }
    function own(o,k) { return Object.prototype.hasOwnProperty.call(o,k); }
    // Tiled 1.12 returns enum PropertyValue wrappers, including inside classes.
    // Resolve the authored name before comparing defaults or validating IDs.
    function plainValue(value) {
        if (value && typeof value === "object" && value.typeName &&
            typeof value.value === "number" && typeof tiled !== "undefined" &&
            tiled.project && typeof tiled.project.findTypeByName === "function") {
            var type = tiled.project.findTypeByName(value.typeName);
            if (type && type.isEnum) return type.nameOf(value);
        }
        return value;
    }
    function dict() { return Object.create(null); }
    function instance(o) { return o.room + "_" + o.type + "_" + o.object_id; }
    function issue(out,o,severity,code,property,message,fix) {
        out.push({severity:severity,code:code,file:o.file,room:o.room,layer:o.layer,
            object_id:o.object_id,object_type:o.type,property:property,message:message,
            fix:fix || "Select the reported object and correct its properties, then export again."});
    }
    M.format = function(d) {
        return "[" + d.severity.toUpperCase() + "] " + d.code + " " + (d.file || "?") +
            " room=" + (d.room || "?") + " layer=" + (d.layer || "?") + " object=" + (d.object_id || "?") +
            (d.property ? " property=" + d.property : "") + ": " + d.message + " Fix: " + d.fix;
    };
    M.fingerprint = function(s) {
        // TextFile decodes UTF-8 and may normalize newlines; normalize identically
        // in Lua. UTF-8 encoding keeps non-ASCII paths/text deterministic.
        s = unescape(encodeURIComponent(s.replace(/^\uFEFF/,"").replace(/\r\n/g,"\n")));
        // Defer modulo by zlib's NMAX, preserving the normalized UTF-8 bytes.
        var a=1,b=0,i=0;
        while (i<s.length) {
            var end=Math.min(i+5552,s.length);
            for (;i<end;i++) { a+=s.charCodeAt(i); b+=a; }
            a%=65521; b%=65521;
        }
        return s.length + ":" + a + ":" + b;
    };
    M.fresh = function(registry, room, read, files) {
        if (!registry || registry.version !== 2 || !registry.sources || !Array.isArray(registry.objects) || registry.source_complete===false) return false;
        var base="developer/assets/tiled/maps/";
        for (var path in registry.sources) {
            if (path===base+room+".lua" || path===base+room+".tmx") continue;
            var source=read(path);
            if (source===null || source===undefined || M.fingerprint(source)!==registry.sources[path]) return false;
        }
        for (var i=0;i<files.length;i++) {
            var name=files[i];
            if (/^[^.].*\.lua$/.test(name) && name!==room+".lua" && !own(registry.sources,base+name)) return false;
        }
        return true;
    };
    // Only values in documented class groups are flattened. Explicit legacy
    // flat overrides beat repeated class defaults, just like property_flattener.
    M.flatten = function(properties, kind, schema) {
        var out={}, groups=[];
        for (var k in properties) {
            var v=properties[k];
            if (v && typeof v==="object" && v.typeName && v.value && typeof v.value==="object") groups.push([k,v.value]);
            else out[k]=plainValue(v);
        }
        var variants=schema && schema.objects && schema.objects[kind] || [];
        groups.forEach(function(group) {
            var members={};
            variants.forEach(function(variant) {
                var g=variant.groups && variant.groups[group[0]]; if (g) members=g.members || {};
            });
            for (var field in group[1]) {
                var value=plainValue(group[1][field]), def=members[field];
                if (!own(out,field) || !def || value!==def.default || out[field]===def.default) out[field]=value;
            }
        });
        return out;
    };
    M.collect = function(map,room,schema) {
        var records=[];
        function objectKind(o, properties) {
            if (o.className || o.type) return o.className || o.type;
            // Native TMX reads can leave inherited template classes blank.
            // Match the generated class signature, which survives object renames.
            var matches={};
            Object.keys(schema && schema.objects || {}).forEach(function(kind) {
                schema.objects[kind].forEach(function(variant) {
                    Object.keys(variant.groups || {}).forEach(function(group) {
                        var value=properties[group];
                        if (value && value.typeName===variant.groups[group].className) matches[kind]=true;
                    });
                });
            });
            var kinds=Object.keys(matches);
            return kinds.length===1 ? kinds[0] : "unknown";
        }
        function walk(layers,path,visible) {
            (layers || []).forEach(function(layer) {
                var name=path ? path+"/"+layer.name : layer.name;
                var shown=visible && layer.visible!==false;
                (layer.objects || []).forEach(function(o) {
                    var properties=o.resolvedProperties();
                    var kind=objectKind(o,properties);
                    records.push({room:room,file:map.fileName,layer:name,object_id:o.id,type:kind,name:o.name,
                        visible:shown && o.visible!==false,properties:M.flatten(properties,kind,schema), native:o});
                });
                walk(layer.layers,name,shown);
            });
        }
        walk(map.layers,"",true); return records;
    };
    M.normalize = function(records) {
        var diagnostics=[], byId=dict();
        records.forEach(function(o) {
            if (own(byId,o.object_id)) issue(diagnostics,o,"error","duplicate_object_id",null,"Tiled object ID is repeated in this map.");
            byId[o.object_id]=o;
        });
        records.forEach(function(o) {
            if (o.visible===false) return;
            Object.keys(aliases).forEach(function(alias) {
                var field=aliases[alias], value=o.properties[alias], source=alias;
                if (value===undefined || value===null || value===0 || (typeof value==="object" && value.id===0)) {
                    value=o.properties[field]; source=field;
                    if (typeof value!=="number" && !(value && typeof value==="object")) return;
                }
                var id=Number(typeof value==="object" ? value.id : value), target=byId[id];
                if (!target || target.visible===false || (value && value.map && o.native && value.map!==o.native.map)) {
                    issue(diagnostics,o,"error","dangling_object_reference",source,"The referenced object is missing, hidden, or belongs to another map (ID " + id + ")."); return;
                }
                var targetField=targets[field][target.type];
                if (field==="target_id" && (o.type==="teleporter")!==(target.type==="teleporter")) targetField=null;
                if (!targetField) { issue(diagnostics,o,"error","wrong_object_reference_type",source,"The referenced object cannot supply " + field + "."); return; }
                var key=text(target.properties[targetField]);
                if (!key && targetField==="boss_id" && target.properties.boss_tag) { key=text(target.properties.boss_tag); target.properties[targetField]=key; }
                if (!key) { key=instance(target); target.properties[targetField]=key; }
                o.properties[field]=key;
                delete o.properties[alias];
            });
        });
        return diagnostics;
    };
    function defaultId(o,prefix) {
        var p=o.properties, value=p[prefix+"_id"];
        if (value==="") return instance(o);
        if (text(value)) return text(value);
        if (text(o.name)) return text(o.name);
        if (o.name==="") return instance(o);
        return prefix+"_"+o.room+"_"+o.object_id;
    }
    M.validate = function(localRecords, registry, fresh, room) {
        var diagnostics=[], records=localRecords.slice(), defs=dict(), refs=[], configs=fresh && registry.configs || {};
        if (fresh) (Array.isArray(registry.objects) ? registry.objects : []).forEach(function(o) { if (o.room!==room) records.push(o); });
        else issue(diagnostics,{room:room},"warning","project_index_unverified",null,
            "Cross-room and configuration checks are unverified: the project index is missing or stale.",
            "Export edited maps, run Create Rooms and Validate All in Defold, then re-export this map.");
        function add(ns,key,o) {
            key=text(key); if (!key) return;
            var n=defs[ns] || (defs[ns]=dict()); (n[key] || (n[key]=[])).push(o);
        }
        function ref(ns,key,o,field) { if (text(key)) refs.push({ns:ns,key:text(key),o:o,field:field}); }
        records.forEach(function(o) {
            if (o.visible===false) return;
            var p=o.properties,t=o.type;
            if (o.room===room && t==="teleporter" && (p.teleporter_id==="" || (p.teleporter_id===undefined && o.name==="")))
                issue(diagnostics,o,"error","missing_teleporter_id","teleporter_id","Set a unique teleporter_id; an explicitly blank identity cannot resolve in an unloaded room.");
            if (t==="end_game" && o.room===room) {
                var ending=fresh && registry.completion;
                if (ending && p.completion_id!==ending.id) {
                    var message="Region completion ID '"+String(p.completion_id)+"' must match configured ending ID '"+String(ending.id)+"'.";
                    if (!ending.enabled) message+=" Ending is disabled; use Project > Game Settings... > Ending to match the ID before enabling completion.";
                    issue(diagnostics,o,ending.enabled ? "error":"warning","unknown_completion_id","completion_id",message,
                        "Match the ID in Project > Game Settings... > Ending or correct this region's completion_id and export again.");
                }
                else if (!ending) issue(diagnostics,o,"warning","ending_unverified","completion_id","Run Prepare & Check in Defold to verify the ending relationship.");
            }
            if (t==="teleporter") { add("teleporter",defaultId(o,"teleporter"),o); add("teleporter_pair",p.pair_id,o); ref("teleporter",p.target_id,o,"target_id"); }
            if (t==="timed_door") add("trigger_channel",defaultId(o,"door"),o);
            if (t==="hazard") add("trigger_channel",defaultId(o,"hazard"),o);
            if (t==="elevator") { add("trigger_channel",p.elevator_id,o); if (p.trigger_id!==p.elevator_id) add("trigger_channel",p.trigger_id,o); }
            if (t==="pressure_plate") ref("trigger_channel",p.target_id || defaultId(o,"plate"),o,p.target_id ? "target_id" : "plate_id");
            if (t==="lever") ref("trigger_channel",p.target_id,o,"target_id");
            if (t==="boss") {
                var bossId=p.boss_id || p.boss_tag || instance(o);
                add("boss",bossId,o); if (p.boss_tag && p.boss_tag!==bossId) add("boss",p.boss_tag,o);
                add("boss_selector",p.boss_preset || p.boss_type,o);
            }
            if (t==="boss_arena") add("boss_arena",p.arena_id || ("arena_"+o.room),o);
            if (t==="boss_phase") add("boss_phase",p.phase_id || instance(o),o);
            if (["boss_arena","boss_phase","boss_phase_trigger","boss_weak_point"].indexOf(t)>=0) {
                ref("boss",p.boss_id,o,"boss_id");
                if (!p.boss_id && text(p.boss_preset || p.boss_type).toLowerCase()!=="none") ref("boss_selector",p.boss_preset || p.boss_type,o,"boss_preset");
            }
            if (["boss","boss_phase","boss_phase_trigger"].indexOf(t)>=0) ref("boss_arena",p.arena_id,o,"arena_id");
            var persistent={chest:"chest_id",breakable_wall:"wall_id",save_point:"save_id"}[t];
            if (persistent) add("persistent_"+persistent,p[persistent] || (t==="save_point" && o.name) || instance(o),o);
            ["destination_room","destination_room_id","target_room","target_room_id"].forEach(function(f) { ref("room",p[f],o,f); });
            ["ability_id","require_ability","requires_ability","reward_ability"].forEach(function(f) { if (text(p[f]).toLowerCase()!=="none") ref("ability",p[f],o,f); });
            ["require_key","key_id","required_key"].forEach(function(f) { if (text(p[f]).toLowerCase()!=="none") ref("key",p[f],o,f); });
            if (["dialogue_trigger","npc","sign","lore_item","hint_stone"].indexOf(t)>=0) ref("dialogue",p.dialogue_id,o,"dialogue_id");
            if (o.room===room && ((t==="lever" && !p.target_id && !text(p.set_flag_on)) || (t==="dialogue_trigger" && !p.dialogue_id)))
                issue(diagnostics,o,"warning","blank_reference",t==="lever" ? "target_id" : "dialogue_id","No explicit reference is set; review the intended runtime fallback.");
            if (o.room===room && t==="boss_phase_trigger") {
                var phase=p.phase===undefined ? 1 : Number(p.phase);
                if (!(phase>=1 && phase===Math.floor(phase))) issue(diagnostics,o,"error","invalid_boss_phase","phase","Phase must be a positive integer.");
                if (p.phase_id) issue(diagnostics,o,"warning","unused_phase_id","phase_id","Use numeric phase; the runtime does not consume phase_id here.");
            }
        });
        Object.keys(defs).forEach(function(ns) {
            Object.keys(defs[ns]).forEach(function(key) {
                var bucket=defs[ns][key];
                if (["teleporter","boss","boss_arena","boss_phase"].indexOf(ns)>=0 || ns.indexOf("persistent_")===0) {
                    if (bucket.length>1) bucket.forEach(function(o) {
                        if (o.room===room) issue(diagnostics,o,"error","duplicate_"+ns,null,"ID '"+key+"' is defined by multiple objects.");
                    });
                }
                var pairUsed=bucket.some(function(o) {
                    var direct=defs.teleporter && defs.teleporter[text(o.properties.target_id)];
                    return o.properties.one_way!==true && !(direct && direct.length===1);
                });
                if (ns==="teleporter_pair" && bucket.length!==2) bucket.forEach(function(o) {
                    if (o.room===room) issue(diagnostics,o, pairUsed && (fresh || bucket.length>2) ? "error":"warning","teleporter_pair_cardinality","pair_id",
                        "Pair '"+key+"' has "+bucket.length+" known endpoints; exactly two are required.");
                });
            });
        });
        localRecords.forEach(function(o) {
            var p=o.properties;
            if (o.visible===false || o.type!=="boss_phase_trigger") return;
            var selected=p.boss_id ? (defs.boss && defs.boss[p.boss_id] || []) :
                (defs.boss_selector && defs.boss_selector[p.boss_preset || p.boss_type] || []).filter(function(b) { return b.room===o.room; });
            if (selected.length!==1) return;
            var boss=selected[0], bp=boss.properties, bossId=bp.boss_id || bp.boss_tag || instance(boss), preset=bp.boss_preset || bp.boss_type;
            var count=records.filter(function(m) {
                var mp=m.properties;
                return m.visible!==false && m.type==="boss_phase" && m.room===boss.room &&
                    (!mp.boss_id || mp.boss_id===bossId) && (!(mp.boss_preset || mp.boss_type) || (mp.boss_preset || mp.boss_type)===preset) &&
                    (!mp.arena_id || mp.arena_id===bp.arena_id);
            }).length;
            if (!count && bp.attack_pattern_ids) count=1;
            if (!count && configs.boss_phase_counts) count=configs.boss_phase_counts[preset] || 0;
            if (count && Number(p.phase || 1)>count && !bp.phase_config)
                issue(diagnostics,o,"error","missing_boss_phase","phase","The requested phase exceeds this boss's configured phase count ("+count+").");
        });
        refs.forEach(function(r) {
            var bucket=defs[r.ns] && defs[r.ns][r.key] || [];
            if (r.ns==="boss_selector") bucket=bucket.filter(function(o) { return o.room===r.o.room; });
            if (r.ns==="key") {
                if (configs.keys && !own(configs.keys,r.key) && r.o.room===room)
                    issue(diagnostics,r.o,"warning","unknown_key",r.field,"This is not a built-in key ID; confirm that the custom item is granted elsewhere.");
                return;
            }
            if (r.ns==="ability" || r.ns==="dialogue") {
                var set=configs[r.ns==="ability" ? "abilities":"dialogues"];
                if (set && !own(set,r.key) && r.o.room===room) issue(diagnostics,r.o,"error","missing_"+r.ns,r.field,"Unknown "+r.ns+" '"+r.key+"'.");
                return;
            }
            if (r.ns==="room") {
                if (r.key===room || (fresh && own(registry.sources,"developer/assets/tiled/maps/"+r.key+".lua"))) return;
            }
            if (r.ns==="boss_arena" && configs.arenas && own(configs.arenas,r.key)) return;
            if (r.ns==="trigger_channel" && bucket.length && !bucket.some(function(o) { return o.room===r.o.room || o.type==="elevator"; }))
                issue(diagnostics,r.o,"warning","cross_room_trigger_channel",r.field,"These listeners are in other streamed rooms and must be loaded to receive the channel.");
            var pair=r.ns==="teleporter" && defs.teleporter_pair && defs.teleporter_pair[text(r.o.properties.pair_id)];
            if (!bucket.length && pair && pair.length===2) {
                issue(diagnostics,r.o,"warning","teleporter_target_fallback",r.field,"The explicit target is missing; runtime falls back to the paired endpoint.");
                return;
            }
            if (!bucket.length) issue(diagnostics,r.o,fresh ? "error":"warning","missing_"+r.ns,r.field,
                "No known "+r.ns+" matches '"+r.key+"'."+(fresh ? "":" Cross-room data is unverified."));
            else if (r.ns!=="trigger_channel" && bucket.length>1) issue(diagnostics,r.o,"error","ambiguous_"+r.ns,r.field,"More than one object matches '"+r.key+"'.");
        });
        return diagnostics;
    };
    M.apply = function(records) {
        records.forEach(function(o) {
            if (!o.native) return;
            // Only relationship fields change on the disk-read export copy.
            ["target_id","boss_id","arena_id","door_id","hazard_id","elevator_id","teleporter_id"].forEach(function(field) {
                var value=o.properties[field];
                if (typeof value==="string") o.native.setProperty(field,value);
            });
            Object.keys(aliases).forEach(function(alias) { o.native.removeProperty(alias); });
        });
    };
    M.select = function(map,diagnostics,room) {
        var ids=dict(); diagnostics.forEach(function(d) { if (d.room===room && d.object_id) ids[d.object_id]=true; });
        var selected=[];
        function walk(layers) { (layers || []).forEach(function(l) {
            (l.objects || []).forEach(function(o) { if (ids[o.id]) selected.push(o); }); walk(l.layers);
        }); }
        walk(map.layers); map.selectedObjects=selected;
    };
    return M;
})();
if (typeof module !== "undefined" && module.exports) module.exports=MVTKRelationships;
