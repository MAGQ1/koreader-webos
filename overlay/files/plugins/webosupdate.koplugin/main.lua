--[[--
Checks the webOS App Museum II for a newer version of this KOReader port, and hands the install off
to Preware. webOS-only: this plugin disables itself on every other platform.

How the install actually happens (see webos/launcher.c and CLAUDE.md, "Update prompt from the App
Museum"): KOReader itself is not allowed to talk to other apps or system services on webOS -- only
the small native launcher program has that permission, because webOS ties Luna permissions to the
exact executable it started, and that's the launcher, not luajit. So "Update now" writes the
download link to a file and quits KOReader with a distinct exit code; the launcher (still running,
it started KOReader and waits for it to exit) sees that code, reads the link, and hands it to
Preware, which shows its own install confirmation. Confirmed working on the device 2026-09-23.

@module koplugin.WebOSUpdate
--]]--

local Device = require("device")

-- Nothing here applies to any other platform.
if not (Device.isWebOS and Device:isWebOS()) then
    return { disabled = true }
end

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local socketutil = require("socketutil")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

-- The exit code that tells webos/launcher.c "read the URL file and hand it to Preware".
-- MUST match INSTALL_UPDATE_CODE in webos/launcher.c. Chosen clear of KOReader's own reserved exit
-- codes: 85 restart, 86 mass storage, 87 Cervantes BQ launch, 88 Kobo poweroff/reboot.
local INSTALL_UPDATE_CODE = 89

-- Written right before quitting with INSTALL_UPDATE_CODE; the launcher reads it once, then deletes it.
local UPDATE_URL_FILE = "/media/internal/koreader/webos-update-url"

-- Must be exactly the name this port is registered under in the App Museum (matched case-insensitively
-- by their service, but kept exact here regardless).
local MUSEUM_APP_NAME = "KOReader"

-- Don't hit the App Museum's server more than this often on our own (the menu item always checks).
local CHECK_INTERVAL_SECONDS = 12 * 60 * 60 -- 12 hours
-- Wait a bit after startup so this never competes with KOReader's own startup work.
local STARTUP_DELAY_SECONDS = 6

--- Reads OUR OWN package version (e.g. "1.0.1"), not KOReader's upstream git-rev version: the App
-- Museum tracks this webOS port as a whole, since a user installs one .ipk that bundles a specific
-- KOReader release together with our launcher and overlay.
local function getAppVersion()
    local path = lfs.currentdir() .. "/../appinfo.json"
    local f = io.open(path, "r")
    if not f then
        logger.warn("WebOSUpdate: cannot open", path)
        return nil
    end
    local text = f:read("*a")
    f:close()
    local ok, info = pcall(json.decode, text)
    if not ok or type(info) ~= "table" or type(info.version) ~= "string" then
        logger.warn("WebOSUpdate: could not read a version from", path)
        return nil
    end
    return info.version
end

--- Turns "1.2.3" into {1, 2, 3}, or returns nil if it isn't exactly that shape (the App Museum
-- requires #.#.# version numbers, so anything else is treated as unusable rather than guessed at).
local function parseVersion(v)
    local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
end

local function isNewer(candidate, current)
    for i = 1, 3 do
        if candidate[i] ~= current[i] then
            return candidate[i] > current[i]
        end
    end
    return false
end

local WebOSUpdate = WidgetContainer:extend{
    name = "webosupdate",
    is_doc_only = false,
}

-- A plugin instance is created fresh every time a FileManager or ReaderUI is shown (e.g. once per
-- book opened), but this module itself is loaded once per process, so a module-level local like this
-- persists across those instances: it makes sure the automatic check fires at most once per run,
-- rather than every time the user opens another book.
local already_scheduled = false

function WebOSUpdate:init()
    self.ui.menu:registerToMainMenu(self)
    self:scheduleAutoCheck()
end

function WebOSUpdate:scheduleAutoCheck()
    if already_scheduled then return end
    already_scheduled = true

    local last_check = G_reader_settings:readSetting("webos_update_last_check") or 0
    if os.time() - last_check < CHECK_INTERVAL_SECONDS then
        return
    end
    UIManager:scheduleIn(STARTUP_DELAY_SECONDS, function()
        self:checkForUpdate(false)
    end)
end

--- @param interactive boolean: true from the menu item, always reports a result;
--   false for the automatic background check, which stays silent unless an update is actually found.
function WebOSUpdate:checkForUpdate(interactive)
    local version = getAppVersion()
    local current = version and parseVersion(version)
    if not current then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Could not read this app's own version number.") })
        end
        return
    end

    G_reader_settings:saveSetting("webos_update_last_check", os.time())

    -- device_id is a random per-install UUID KOReader already generates at startup (frontend/random.lua,
    -- see reader.lua) for things like sync; reusing it here means we send no hardware/serial identifier.
    local client_id = G_reader_settings:readSetting("device_id") or ""
    local url = string.format(
        "http://appcatalog.webosarchive.org/WebService/getLatestVersionInfo.php?app=%s%%2F%s&clientid=%s&device=%s",
        MUSEUM_APP_NAME:gsub(" ", "%%20"), version, client_id, "TouchPad%2F3.1.0%2FWiFi%2Fen_us")

    socketutil:set_timeout(10, 20)
    local ok, body, code = pcall(function() return http.request(url) end)
    socketutil:reset_timeout()

    if not ok or code ~= 200 or not body then
        logger.warn("WebOSUpdate: check failed:", ok, code)
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Could not reach the App Museum. Check your Wi-Fi and try again.") })
        end
        return
    end

    local decode_ok, response = pcall(json.decode, body)
    if not decode_ok or type(response) ~= "table" then
        logger.warn("WebOSUpdate: unreadable response:", body)
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("The App Museum sent back something unexpected.") })
        end
        return
    end
    if type(response.version) ~= "string" then
        -- Most likely the app isn't listed in the Museum yet ({"error": "..."}); that's expected pre-launch.
        logger.info("WebOSUpdate: no version in response:", body)
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("This app isn't listed in the App Museum yet.") })
        end
        return
    end

    local candidate = parseVersion(response.version)
    if not candidate or not isNewer(candidate, current) then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("You're running the latest version.") })
        end
        return
    end

    self:promptForUpdate(response)
end

function WebOSUpdate:promptForUpdate(response)
    local note = response.versionNote or ""
    UIManager:show(ConfirmBox:new{
        text = T(_("A newer version (%1) is available.\n\n%2\n\nInstall it now via Preware?"),
            response.version, note),
        ok_text = _("Update now"),
        ok_callback = function()
            self:requestInstall(response.downloadURI)
        end,
        cancel_text = _("Later"),
    })
end

function WebOSUpdate:requestInstall(download_uri)
    if not download_uri or download_uri == "" then
        UIManager:show(InfoMessage:new{ text = _("The App Museum did not give a download link.") })
        return
    end
    local f = io.open(UPDATE_URL_FILE, "w")
    if not f then
        UIManager:show(InfoMessage:new{ text = _("Could not write the update request file.") })
        return
    end
    f:write(download_uri, "\n")
    f:close()
    -- The launcher takes it from here (see webos/launcher.c): it reads this file, hands the link to
    -- Preware, and does not restart KOReader -- the user finishes the install in Preware.
    UIManager:quit(INSTALL_UPDATE_CODE)
end

function WebOSUpdate:addToMainMenu(menu_items)
    menu_items.webos_check_for_update = {
        text = _("Check for KOReader updates"),
        sorting_hint = "more_tools",
        callback = function()
            self:checkForUpdate(true)
        end,
    }
end

return WebOSUpdate
