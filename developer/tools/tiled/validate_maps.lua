-- developer/tools/tiled/validate_maps.lua
-- Simple Lua-only validator for Tiled Lua exports.
-- Scans developer/assets/tiled/maps and ensures each .lua export loads and returns a table.

local maps_dir = "developer/assets/tiled/maps"
local shared = rawget(_G, "_MVTK")
local lfs_ok, lfs = pcall(require, "lfs")

local function os_path(path)
  if shared and type(shared.to_os_path) == "function" then
    return shared.to_os_path(path)
  end
  return path
end

local function join_path(left, right)
  if shared and type(shared.join) == "function" then
    return shared.join(left, right)
  end
  if not left or left == "" then
    return right
  end
  if left:sub(-1) == "/" or left:sub(-1) == "\\" then
    return left .. right
  end
  return left .. "/" .. right
end

local function absolute_maps_dir()
  if shared and shared.ROOT and type(shared.ROOT) == "string" and shared.ROOT ~= "" then
    return join_path(shared.ROOT, maps_dir)
  end
  return maps_dir
end

local function collect_lines(cmd)
  local lines = {}
  if io and io.popen then
    local ok_proc, proc = pcall(io.popen, cmd)
    if ok_proc and proc then
      for line in proc:lines() do
        if line ~= "" and line ~= "." and line ~= ".." then
          lines[#lines + 1] = line
        end
      end
      proc:close()
      if #lines > 0 then
        return lines
      end
    end
  end

  if os and os.execute and type(os.execute) == "function" then
    local tmp = "hooks/.validate_maps.tmp"
    local redirect = package.config and package.config:sub(1, 1) == "\\" and " 2>nul" or " 2>/dev/null"
    os.execute(cmd .. ' > "' .. tmp .. '"' .. redirect)
    local fh = io.open(tmp, "r")
    if fh then
      for line in fh:lines() do
        if line ~= "" and line ~= "." and line ~= ".." then
          lines[#lines + 1] = line
        end
      end
      fh:close()
    end
    pcall(os.remove, tmp)
  end

  return lines
end

local function list_map_files()
  local files = {}
  local abs_maps_dir = absolute_maps_dir()

  if shared and type(shared.list_dir_filesystem) == "function" then
    local ok_list, _, listed_files = pcall(shared.list_dir_filesystem, abs_maps_dir)
    if ok_list and type(listed_files) == "table" then
      for _, file in ipairs(listed_files) do
        if type(file) == "string" and file:match("%.lua$") then
          files[#files + 1] = file
        end
      end
      if #files > 0 then
        table.sort(files)
        return files
      end
    end
  end

  if lfs_ok and lfs then
    local dir_path = os_path(abs_maps_dir)
    local mode = lfs.attributes(dir_path, "mode")
    if mode == "directory" then
      for file in lfs.dir(dir_path) do
        if file:match("%.lua$") then
          files[#files + 1] = file
        end
      end
      table.sort(files)
      return files
    end
  end

  local is_windows = package.config and package.config:sub(1, 1) == "\\"
  local dir_path = os_path(abs_maps_dir)
  local lines
  if is_windows then
    lines = collect_lines(string.format('cmd /c dir /b /a-d "%s"', dir_path))
  else
    lines = collect_lines(string.format('ls -1 "%s"', dir_path))
  end
  for _, file in ipairs(lines) do
    if type(file) == "string" and file:match("%.lua$") then
      files[#files + 1] = file
    end
  end

  table.sort(files)
  return files
end

local load_fn = loadstring or load

local function load_map_file(path)
  local fh = io.open(os_path(path), "rb")
  if not fh then
    return false, "could not open file"
  end
  local content = fh:read("*a")
  fh:close()

  local chunk, compile_err = load_fn(content, "@" .. path)
  if not chunk then
    return false, compile_err
  end

  local ok, result = pcall(chunk)
  if not ok then
    return false, result
  end
  return true, result
end

local function validate_file(path, name)
  local ok, result = load_map_file(path)
  if not ok then
    print(string.format("[TILED_VALIDATE] ERROR loading %s: %s", name, tostring(result)))
    return false
  end
  if type(result) ~= "table" then
    print(string.format("[TILED_VALIDATE] ERROR %s did not return a table", name))
    return false
  end
  return true
end

local files = list_map_files()
if #files == 0 then
  print(string.format("[TILED_VALIDATE] ERROR no Tiled Lua maps found in %s", maps_dir))
  os.exit(1)
end

local all_ok = true
local abs_maps_dir = absolute_maps_dir()
for _, file in ipairs(files) do
  local full = join_path(abs_maps_dir, file)
  local ok = validate_file(full, file)
  all_ok = all_ok and ok
end

if all_ok then
  print(string.format("[TILED_VALIDATE] All %d Tiled Lua maps loaded successfully.", #files))
else
  print("[TILED_VALIDATE] Map validation failed.")
  os.exit(1)
end
