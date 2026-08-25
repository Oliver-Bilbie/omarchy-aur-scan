-- obilbie.aur-scan
local util = require("hooks.obilbie-aur-scan.util")

local M = {}

local SUPPORTED_AGENTS = {
   opencode = true,
   gemini = true,
   claude = true,
   grok = true,
   codex = true,
   omp = true,
   pi = true,
   crush = true,
}

local function skip_message(agent)
   local why
   if agent == "copilot" then
      why = "GitHub Copilot cannot be pointed at the secrets broker."
   else
      why = agent .. " cannot be sandboxed for AUR investigation."
   end
   return "Skipping AI investigation: " .. why .. "\n" ..
       "Choose a different default agent with: omarchy default agent <name>\n" ..
       "Supported: claude, codex, crush, gemini, grok, omp, opencode, pi\n"
end

function M.investigation_skip_reason()
   if not util.command_exists("omarchy-default-agent") then
      return nil
   end
   local agent = util.read_trim("omarchy-default-agent 2>/dev/null")
   if not agent or SUPPORTED_AGENTS[agent] then
      return nil
   end
   return skip_message(agent)
end

local function plugin_dir()
   local xdg = os.getenv("XDG_CONFIG_HOME")
   local home = os.getenv("HOME")
   local candidates = {}
   if type(xdg) == "string" and xdg ~= "" then
      candidates[#candidates + 1] = xdg .. "/omarchy/plugins/obilbie.aur-scan"
   end
   if type(home) == "string" and home ~= "" then
      candidates[#candidates + 1] = home .. "/.config/omarchy/plugins/obilbie.aur-scan"
   end
   for i = 1, #candidates do
      if util.file_readable(candidates[i] .. "/omarchy-agent-sandbox.sh")
          and util.file_readable(candidates[i] .. "/broker.py") then
         return candidates[i]
      end
   end
   return nil
end

function M.launch(name, path, report)
   local home = os.getenv("HOME")
   if type(home) ~= "string" or home == "" then
      util.write_tty("HOME is unset; skipping AI investigation.\n")
      return
   end

   local dir = plugin_dir()
   if not dir then
      util.write_tty("AUR scan sandbox scripts are missing from the plugin directory.\n")
      return
   end

   if not util.command_exists("omarchy-launch-tui") then
      util.write_tty("omarchy-launch-tui is missing; skipping AI investigation.\n")
      return
   end

   local pkgdir = util.realpath_of(path)
   if not pkgdir then
      util.write_tty("package directory not found: " .. tostring(path) .. "\n")
      return
   end
   local cache = util.realpath_of(home .. "/.cache/yay")
   if not cache or pkgdir:sub(1, #cache + 1) ~= cache .. "/" then
      util.write_tty("refusing to run outside yay cache: " .. pkgdir .. "\n")
      return
   end

   if type(name) ~= "string" or name == "" then
      name = "unknown"
   end

   local tmp = os.getenv("TMPDIR")
   if type(tmp) ~= "string" or tmp == "" then
      tmp = "/tmp"
   end
   local report_file = util.read_trim("mktemp " .. util.sh_quote(tmp .. "/obilbie-aur-scan-report.XXXXXX") .. " 2>/dev/null")
   if not report_file then
      util.write_tty("Failed to create report file.\n")
      return
   end
   local ok, werr = util.write_file(report_file, util.sanitize_prompt(report or ""))
   if not ok then
      util.write_tty("Failed to write scan report: " .. tostring(werr or "unknown error") .. "\n")
      return
   end

   local argv = {
      dir .. "/omarchy-agent-sandbox.sh",
      "--package", pkgdir,
      "--name", name,
      "--report", report_file,
   }
   local launched, launch_err = util.shell_ok("(" .. util.sh_join(argv) .. ") >/dev/null 2>&1 &")
   if not launched then
      util.write_tty("Failed to launch AI agent: " .. tostring(launch_err or "unknown error") .. "\n")
      return
   end
   util.write_tty("AI agent launched in a sandboxed window.\n")
end

return M
