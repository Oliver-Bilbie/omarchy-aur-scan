-- obilbie.aur-scan
local util = require("hooks.obilbie-aur-scan.util")
local agent = require("hooks.obilbie-aur-scan.agent")

local function read_severity()
   local xdg = os.getenv("XDG_STATE_HOME")
   local home = os.getenv("HOME")
   local dir
   if type(xdg) == "string" and xdg ~= "" then
      dir = xdg .. "/omarchy/obilbie.aur-scan"
   elseif type(home) == "string" and home ~= "" then
      dir = home .. "/.local/state/omarchy/obilbie.aur-scan"
   else
      util.abort("Could not locate severity setting: HOME and XDG_STATE_HOME are unset.")
   end
   local path = dir .. "/severity"
   local f, err = io.open(path, "r")
   if not f then
      util.abort("Could not read severity setting at " .. path .. ": " .. tostring(err or "file not found"))
   end
   local value = f:read("*l")
   f:close()
   if type(value) ~= "string" then
      util.abort("Severity setting at " .. path .. " is empty.")
   end
   value = value:match("^%s*(.-)%s*$")
   if value ~= "critical" and value ~= "high" and value ~= "medium"
       and value ~= "low" and value ~= "info" then
      util.abort("Invalid severity setting " .. string.format("%q", value) .. " in " .. path)
   end
   return value
end

local function run_aur_scan(path, severity)
   local flags = " --severity " .. util.sh_quote(severity) .. " --fail-on " .. util.sh_quote(severity)
   if severity == "info" then
      flags = flags .. " --include-info"
   end
   local cmd = "env -u NO_COLOR CLICOLOR_FORCE=1 aur-scan scan" .. flags .. " " .. util.sh_quote(path)
       .. " 2>&1; printf '\\n__AUR_SCAN_EXIT__%d' $?"
   local pipe = io.popen(cmd)
   if not pipe then
      return nil, nil, "failed to start aur-scan"
   end
   local output = pipe:read("*a")
   pipe:close()
   if type(output) ~= "string" then
      return nil, nil, "failed to read aur-scan output"
   end
   local body, code = output:match("^(.*)\n__AUR_SCAN_EXIT__(%d+)%s*$")
   if not body or not code then
      return nil, nil, "could not determine aur-scan exit status"
   end
   return body, tonumber(code)
end

yay.create_autocmd("AURPreInstall", {
   desc = "Scan AUR package sources before install",
   callback = function(event)
      if type(event) ~= "table" or type(event.data) ~= "table" then
         util.abort("AURPreInstall event is missing.")
      end

      local path = event.data.dir
      if type(path) ~= "string" or path == "" then
         util.abort("The installation directory does not exist, so it could not be scanned.")
      end

      local pkgbuild = event.data.pkgbuild_path
      if type(pkgbuild) ~= "string" or pkgbuild == "" then
         pkgbuild = path .. "/PKGBUILD"
      end
      if not util.file_readable(pkgbuild) then
         util.abort("PKGBUILD not found at " .. pkgbuild .. ", so it could not be scanned.")
      end

      if not util.command_exists("aur-scan") then
         util.abort("aur-scan is not installed or not on PATH.")
      end

      local output, code, err = run_aur_scan(path, read_severity())
      if not output then
         util.abort("aur-scan failed to run: " .. tostring(err))
      end
      if output == "" then
         util.abort("aur-scan produced no output.")
      end

      local plain = util.strip_ansi(output)
      if plain:match("PKGBUILD not found") or plain:match("[Ee]rror:") then
         util.abort("aur-scan reported an error:\n" .. util.sanitize_prompt(output))
      end
      if code ~= 0 and code ~= 1 then
         local detail = util.sanitize_prompt(output)
         if detail == "" then
            detail = "exit status " .. tostring(code)
         end
         util.abort("aur-scan failed:\n" .. detail)
      end

      local name = event.match or event.data.base or ""
      if type(name) ~= "string" then
         name = ""
      end

      -- variables aren't resolved in the output, so we substitute pkgname here
      output = output:gsub("%$_pkgname", name)
      output = output:gsub("%$pkgname", name)

      local ok, werr = util.write_tty(output)
      if not ok then
         util.abort("Could not display aur-scan results: " .. tostring(werr))
      end

      local issues_found = code == 1
      if issues_found then
         local skip = agent.investigation_skip_reason()
         if skip then
            util.write_tty(skip)
         elseif util.user_response("Investigate with AI agent?") then
            agent.launch(name, path, output)
         end
         if not util.user_response("Continue with installation?") then
            util.abort("Operation aborted by user.")
         end
      end
   end,
})
