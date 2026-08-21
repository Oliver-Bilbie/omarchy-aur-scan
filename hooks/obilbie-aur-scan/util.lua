-- obilbie.aur-scan
local M = {}

function M.strip_ansi(s)
   return tostring(s):gsub("\27%[[%d;]*[A-Za-z]", "")
end

function M.strip_controls(s)
   return tostring(s):gsub("[%z\1-\8\11-\31\127]", "")
end

function M.sanitize_prompt(s)
   s = M.strip_ansi(s)
   s = M.strip_controls(s)
   s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
   s = s:gsub("\n\n\n+", "\n\n")
   return s
end

function M.sh_quote(s)
   return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.abort(msg)
   yay.abort(tostring(msg))
end

function M.write_tty(s)
   local tty, err = io.open("/dev/tty", "w")
   if not tty then
      return nil, err or "could not open /dev/tty"
   end
   local ok, werr = tty:write(s)
   tty:flush()
   tty:close()
   if not ok then
      return nil, werr or "could not write to /dev/tty"
   end
   return true
end

function M.user_response(prompt)
   local tty, err = io.open("/dev/tty", "r+")
   if not tty then
      M.abort("No TTY available for confirmation: " .. tostring(err or "unknown error"))
   end
   local answer
   local attempts = 0
   repeat
      attempts = attempts + 1
      if attempts > 50 then
         tty:close()
         M.abort("Too many invalid confirmation responses")
      end
      local ok, werr = tty:write(prompt .. " (y/n) ")
      if not ok then
         tty:close()
         M.abort("Failed to write confirmation prompt: " .. tostring(werr or "unknown error"))
      end
      tty:flush()
      answer = tty:read("*l")
      if not answer then
         tty:close()
         M.abort("No response")
      end
      answer = answer:match("^%s*(.-)%s*$")
   until answer == "y" or answer == "Y" or answer == "n" or answer == "N"
   tty:close()
   return answer == "y" or answer == "Y"
end

function M.file_readable(path)
   if type(path) ~= "string" or path == "" then
      return false
   end
   local f = io.open(path, "r")
   if not f then
      return false
   end
   f:close()
   return true
end

function M.command_exists(name)
   local pipe = io.popen("command -v " .. M.sh_quote(name) .. " >/dev/null 2>&1 && printf yes")
   if not pipe then
      return false
   end
   local out = pipe:read("*a") or ""
   pipe:close()
   return out == "yes"
end

function M.sh_join(args)
   local parts = {}
   for i = 1, #args do
      parts[i] = M.sh_quote(args[i])
   end
   return table.concat(parts, " ")
end

function M.read_trim(cmd)
   local pipe = io.popen(cmd)
   if not pipe then
      return nil
   end
   local out = pipe:read("*a") or ""
   pipe:close()
   out = out:match("^%s*(.-)%s*$")
   if out == "" then
      return nil
   end
   return out
end

function M.realpath_of(path)
   return M.read_trim("realpath " .. M.sh_quote(path) .. " 2>/dev/null")
end

function M.shell_ok(cmd)
   local pipe = io.popen(cmd .. " 2>&1; printf '\\n__EXIT__%d' $?")
   if not pipe then
      return false, "failed to start command"
   end
   local output = pipe:read("*a") or ""
   pipe:close()
   local body, code = output:match("^(.*)\n__EXIT__(%d+)%s*$")
   if not code then
      if output ~= "" then
         return false, output
      end
      return false, "could not determine exit status"
   end
   if tonumber(code) ~= 0 then
      if type(body) == "string" then
         body = body:match("^%s*(.-)%s*$")
      end
      if type(body) == "string" and body ~= "" then
         return false, body
      end
      return false, "exit " .. code
   end
   return true
end

function M.env_or(name, fallback)
   local v = os.getenv(name)
   if type(v) == "string" and v ~= "" then
      return v
   end
   return fallback
end

function M.write_file(path, contents)
   local f, err = io.open(path, "w")
   if not f then
      return nil, err
   end
   local ok, werr = f:write(contents)
   f:close()
   if not ok then
      return nil, werr
   end
   return true
end

return M
