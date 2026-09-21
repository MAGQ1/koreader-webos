-- HP TouchPad running webOS 3.x (the original Palm/HP webOS, not LG webOS).
-- Screen and touch come from SDL 1.2 + PDL (see ffi/SDL1_2.lua).
local Generic = require("device/generic/device") -- <= look at this file!
local logger = require("logger")

local function yes() return true end
local function no() return false end

local WebOS = Generic:extend{
    model = "HP TouchPad",
    isWebOS = yes,
    isTouchDevice = yes,
    hasMultitouch = yes,
    hasKeys = no,
    hasDPad = no,
    -- The tilt sensor drives auto-rotation (via EV_MSC:MSC_GYRO, see ffi/SDL1_2.lua). This also
    -- enables KOReader's "ignore accelerometer" / "lock auto rotation" options.
    hasGSensor = yes,
    hasFrontlight = no,
    hasBattery = no, -- TODO: read it from the webOS power service
    hasWifiToggle = no,
    hasEinkScreen = no,
    hasColorScreen = yes,
    hasSystemFonts = yes,
    canSuspend = no,
    canStandby = no,
    canReboot = no,
    canPowerOff = no,
    isDefaultFullscreen = yes,
    needsScreenRefreshAfterResume = no,
    -- User storage on webOS: this is the partition that is visible over USB.
    home_dir = "/media/internal",
    -- 9.7" 1024x768 panel (real density is 132 dpi). KOReader sizes its UI from this number; 100 makes
    -- everything a bit smaller than the panel's true density would, which the owner preferred on this
    -- tablet. Users can still change it in Settings > Screen > Screen DPI.
    screen_dpi = 100,
}

function WebOS:init()
    self.screen = require("ffi/framebuffer_webos"):new{
        device = self,
        debug = logger.dbg,
    }

    self.input = require("device/input"):new{
        device = self,
        -- No hardware keys worth mapping: touch is everything.
        event_map = {},
        handleMiscEv = function(this, ev)
            local backend = this.input
            if ev.code == backend.MSC_GYRO then
                -- Tilt sensor: let the standard handler decide (honours the ignore / lock settings).
                return this:handleGyroEv(ev)
            elseif ev.code == backend.MSC_QUIT then
                -- The card was closed (swipe up in the card view) or the OS asked us to quit.
                return "Exit"
            elseif ev.code == backend.MSC_HIDE then
                -- Minimized: make sure nothing is lost if the OS kills us while we're in the background.
                require("ui/uimanager"):flushSettings()
            elseif ev.code == backend.MSC_SHOW then
                -- Back in front: the compositor may have dropped our pixels, so repaint everything.
                require("ui/uimanager"):setDirty("all", "ui")
            end
        end,
    }
    -- The framebuffer already opened SDL; this is a no-op that keeps the input API uniform.
    self.input:open()

    Generic.init(self)
end

-- Not a supported updater target: updates come as a new .ipk.
function WebOS:otaModel() return nil end

function WebOS:initNetworkManager(NetworkMgr)
    -- Wi-Fi is managed by webOS; assume the connection is up and let requests fail naturally if it's not.
    function NetworkMgr:isWifiOn() return true end
    function NetworkMgr:isConnected() return true end
end

return WebOS
