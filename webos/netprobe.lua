-- Self-test that runs INSIDE the webOS app jail instead of KOReader, when the launcher finds the marker file
-- /media/internal/koreader/net-probe. It answers two questions that decide how update prompts can work:
--   1. can the jail resolve names and fetch a web page (App Museum's update web service)?
--   2. can the jail call system services (to hand a download to Preware)?
-- Results go to the launcher log (/media/internal/koreader/webos-launcher.log). Delete the marker to disable.
io.stdout:setvbuf("line")
print("=== netprobe: start")

local function show_file(path)
    local f = io.open(path, "r")
    if not f then print("file " .. path .. ": not visible in the jail"); return end
    local text = f:read("*a") or ""
    f:close()
    print("file " .. path .. ": " .. #text .. " bytes; first lines: " .. text:sub(1, 200):gsub("\n", " | "))
end
show_file("/etc/resolv.conf")
show_file("/var/run/resolv.conf")

-- KOReader's Lua paths (this script replaces reader.lua, which normally does it)
require("setupkoenv")

local ok, socket = pcall(require, "socket")
print("luasocket:", ok, ok and socket._VERSION or socket)
if ok then
    for _, host in ipairs({ "appcatalog.webosarchive.org", "example.com" }) do
        local ip, err = socket.dns.toip(host)
        print("DNS " .. host .. " ->", ip, err)
    end

    local http = require("socket.http")
    http.TIMEOUT = 15
    local url = "http://appcatalog.webosarchive.org/WebService/getLatestVersionInfo.php"
        .. "?app=KOReader%2F1.0.0&clientid=netprobe&device=TouchPad%2F3.1.0%2FWiFi%2Fen_us"
    local body, code, _, status = http.request(url)
    print("HTTP GET update service ->", code, status)
    print("body (first 300 chars):", body and body:sub(1, 300) or "(none)")
end

-- (Calling system services from here does NOT work: this program is not the one webOS gave the app's
-- Luna permissions to. Only the launcher process may, see launcher.c pdl_probe().)
print("=== netprobe: done")
