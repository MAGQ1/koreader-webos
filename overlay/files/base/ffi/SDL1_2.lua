--[[--
SDL 1.2 + PDL bindings for the HP TouchPad (webOS 3.x).

The TouchPad only ships Palm's SDL 1.2 (libSDL-1.2.so.0) and libpdl, so this is the webOS
counterpart of ffi/SDL3.lua. It does two jobs for the frontend:

  * video: open a full-screen software surface and flip a KOReader blitbuffer onto it;
  * input: turn Palm's SDL mouse events (one "finger" index per touch point, in the
    non-standard `which` field) into the fake Linux multitouch events (ABS_MT_*) that
    frontend/device/input.lua already knows how to turn into taps, swipes and pinches.

See webos://knowledge/pdk: PDL_Init must run before SDL_Init.
--]]

local ffi = require("ffi")
local bit = require("bit")
local C = ffi.C

require("ffi/posix_h")
require("ffi/linux_input_h")

ffi.cdef[[
typedef struct { int16_t x, y; uint16_t w, h; } SDL12_Rect;
typedef struct { uint8_t r, g, b, unused; } SDL12_Color;
typedef struct { int ncolors; SDL12_Color *colors; } SDL12_Palette;
typedef struct {
    SDL12_Palette *palette;
    uint8_t BitsPerPixel, BytesPerPixel;
    uint8_t Rloss, Gloss, Bloss, Aloss;
    uint8_t Rshift, Gshift, Bshift, Ashift;
    uint32_t Rmask, Gmask, Bmask, Amask;
    uint32_t colorkey;
    uint8_t alpha;
} SDL12_PixelFormat;
typedef struct {
    uint32_t flags;
    SDL12_PixelFormat *format;
    int w, h;
    uint16_t pitch;
    void *pixels;
    int offset;
    void *hwdata;
    SDL12_Rect clip_rect;
    uint32_t unused1;
    uint32_t locked;
    void *map;
    unsigned int format_version;
    int refcount;
} SDL12_Surface;

typedef struct { uint8_t type; uint8_t gain; uint8_t state; } SDL12_ActiveEvent;
typedef struct { uint8_t type; uint8_t which; uint8_t state; uint16_t x, y; int16_t xrel, yrel; } SDL12_MouseMotionEvent;
typedef struct { uint8_t type; uint8_t which; uint8_t button; uint8_t state; uint16_t x, y; } SDL12_MouseButtonEvent;
typedef union {
    uint8_t type;
    SDL12_ActiveEvent active;
    SDL12_MouseMotionEvent motion;
    SDL12_MouseButtonEvent button;
    uint8_t _pad[64]; /* the real SDL_Event is smaller than this */
} SDL12_Event;

int SDL_Init(uint32_t flags);
void SDL_Quit(void);
const char *SDL_GetError(void);
SDL12_Surface *SDL_SetVideoMode(int width, int height, int bpp, uint32_t flags);
int SDL_Flip(SDL12_Surface *screen);
int SDL_LockSurface(SDL12_Surface *surface);
void SDL_UnlockSurface(SDL12_Surface *surface);
int SDL_PollEvent(SDL12_Event *event);
int SDL_WaitEvent(SDL12_Event *event);
void SDL_Delay(uint32_t ms);
uint32_t SDL_GetTicks(void);
int SDL_ShowCursor(int toggle);

int PDL_Init(unsigned int flags);
int PDL_SetTouchAggression(int aggression);
int PDL_GesturesEnable(int enable);
void PDL_Quit(void);
int PDL_SensorExists(int sensor);
int PDL_EnableSensor(int sensor, int enable);
int PDL_PollSensor(int sensor, void *event);
]]

-- Constants from SDL.h / SDL_events.h / PDL_types.h.
local SDL_INIT_VIDEO = 0x00000020
local SDL_SWSURFACE = 0x00000000
local SDL_FULLSCREEN = 0x80000000

local SDL_ACTIVEEVENT = 1
local SDL_MOUSEMOTION = 4
local SDL_MOUSEBUTTONDOWN = 5
local SDL_MOUSEBUTTONUP = 6
local SDL_QUIT = 12
local SDL_VIDEOEXPOSE = 17

local PDL_AGGRESSION_MORETOUCHES = 1
local PDL_SENSOR_ORIENTATION = 7

-- The TouchPad panel.
local SCREEN_W, SCREEN_H, SCREEN_BPP = 1024, 768, 16
local MAX_FINGERS = 5
-- Poll interval while waiting: SDL 1.2 has no SDL_WaitEventTimeout, and the tilt sensor is polled too.
local POLL_MS = 15
local SENSOR_POLL_MS = 100

-- Custom EV_MSC codes, consumed by handleMiscEv in frontend/device/webos/device.lua.
-- (Rotation goes through KOReader's standard EV_MSC:MSC_GYRO instead.)
local S = {
    MSC_QUIT = 0x7001,
    MSC_HIDE = 0x7002,
    MSC_SHOW = 0x7003,
    MSC_GYRO = tonumber(C.MSC_GYRO),
    w = SCREEN_W,
    h = SCREEN_H,
}

-- PDL_SENSOR_ORIENTATION reading -> KOReader rotation mode.
-- Measured on a real TouchPad (webOS 3.0.5 / CE 3.1.0); note that Palm's names are NOT what they
-- sound like, so this table is by pose, not by name. The screen buffer is landscape with the
-- home button on the right; with KOReader's is_always_portrait, mode 0 (upright portrait) is that
-- buffer rotated by 90 degrees.
--   sensor 6 (RIGHT_SIDE_DOWN): landscape, home button on the right   -> mode 3
--   sensor 4 (UP_SIDE_DOWN):    portrait,  home button at the bottom  -> mode 0
--   sensor 5 (LEFT_SIDE_DOWN):  landscape, home button on the left    -> mode 1
--   sensor 3 (NORMAL):          portrait,  home button at the top     -> mode 2
-- Face up / face down / unknown (1, 2, 0) are ignored so the picture doesn't flip when laid flat.
local ORIENTATION_TO_MODE = {
    [6] = tonumber(C.DEVICE_ROTATED_COUNTER_CLOCKWISE),
    [4] = tonumber(C.DEVICE_ROTATED_UPRIGHT),
    [5] = tonumber(C.DEVICE_ROTATED_CLOCKWISE),
    [3] = tonumber(C.DEVICE_ROTATED_UPSIDE_DOWN),
}

-- Touch diagnostics: create /media/internal/koreader/touch-debug (an empty file) and restart KOReader
-- to log every touch-down as raw panel coordinates -> logical coordinates, with the rotation in use.
local touch_debug = false

local SDL = ffi.load("libSDL-1.2.so.0")
local PDL = ffi.load("libpdl.so")

local function sdlError()
    return ffi.string(SDL.SDL_GetError())
end

function S.open()
    if S.screen then return true end

    PDL.PDL_Init(0) -- must come before SDL_Init
    PDL.PDL_SetTouchAggression(PDL_AGGRESSION_MORETOUCHES)
    -- Keep the system edge-swipe gestures out of our touches.
    PDL.PDL_GesturesEnable(0)

    if SDL.SDL_Init(SDL_INIT_VIDEO) < 0 then
        error("SDL_Init failed: " .. sdlError())
    end
    SDL.SDL_ShowCursor(0)

    local screen = SDL.SDL_SetVideoMode(SCREEN_W, SCREEN_H, SCREEN_BPP, bit.bor(SDL_SWSURFACE, SDL_FULLSCREEN))
    if screen == nil then
        error("SDL_SetVideoMode failed: " .. sdlError())
    end
    S.screen = screen
    S.w, S.h = screen.w, screen.h
    S.pitch = screen.pitch
    S.bpp = screen.format.BitsPerPixel
    -- KOReader's BBRGB16 is RGB565: that lets us copy the buffer as-is, no conversion.
    S.is_rgb565 = screen.format.Rmask == 0xF800 and screen.format.Gmask == 0x07E0 and screen.format.Bmask == 0x001F

    -- Make stdout line-buffered so the launcher's log is complete even if we get killed.
    io.stdout:setvbuf("line")
    local dbg = io.open("/media/internal/koreader/touch-debug", "r")
    if dbg then
        dbg:close()
        touch_debug = true
    end

    -- Tilt sensor, for auto-rotation.
    if PDL.PDL_SensorExists(PDL_SENSOR_ORIENTATION) ~= 0 then
        S.has_orientation = PDL.PDL_EnableSensor(PDL_SENSOR_ORIENTATION, 1) == 0
    end
    return true
end

--- Copy a whole blitbuffer (RGB16, same size as the screen) onto the screen and flip.
-- We always copy the full frame: the surface may be double buffered, in which case a partial
-- copy would leave stale pixels in the other buffer. 1024*768*2 bytes is only 1.5 MB.
function S.flip(bb)
    local screen = S.screen
    if screen == nil then return end
    S.last_bb = bb

    if SDL.SDL_LockSurface(screen) ~= 0 then return end
    local dst = ffi.cast("uint8_t *", screen.pixels)
    local src = ffi.cast("uint8_t *", bb.data)
    local row_bytes = S.w * 2
    if bb.stride == S.pitch then
        ffi.copy(dst, src, S.pitch * S.h)
    else
        for y = 0, S.h - 1 do
            ffi.copy(dst + y * S.pitch, src + y * bb.stride, row_bytes)
        end
    end
    SDL.SDL_UnlockSurface(screen)
    SDL.SDL_Flip(screen)
end

function S.close()
    if S.screen then
        SDL.SDL_Quit()
        PDL.PDL_Quit()
        S.screen = nil
    end
end

-- One SDL event can generate more than one event for koreader, so this is a FIFO queue.
local inputQueue = {}

local function genEmuEvent(evtype, code, value)
    local timespec = ffi.new("struct timespec")
    C.clock_gettime(C.CLOCK_MONOTONIC_COARSE, timespec)
    table.insert(inputQueue, {
        type = tonumber(evtype),
        code = tonumber(code),
        value = tonumber(value) or value,
        time = {
            sec = tonumber(timespec.tv_sec),
            usec = math.floor(tonumber(timespec.tv_nsec / 1000)),
        },
    })
end

-- Touch coordinates.
--
-- The panel is landscape (1024x768) but KOReader treats the device as a portrait one
-- (is_always_portrait, see framebuffer_webos.lua): "upright" is the portrait view with the home
-- button at the bottom, 768 wide and 1024 tall. Touches must be reported in THAT frame, whatever
-- the current rotation is: frontend/device/gesturedetector.lua rotates gesture coordinates itself
-- according to Screen:getTouchRotation(). (Rotating them here as well applies the rotation twice,
-- which is right only in the upright pose. Same conversion as Input:adjustTouchSwitchAxesAndMirrorX
-- uses for the SDL emulator in portrait.)
local function toLogical(px, py)
    return S.h - 1 - py, px
end

-- finger index (0..4) -> tracking id while that finger is down
local active_fingers = {}
local next_tracking_id = 1

local function fingerDown(finger, x, y)
    local rx, ry = x, y
    x, y = toLogical(x, y)
    if touch_debug then
        io.stderr:write(string.format("touch-debug: raw=(%d,%d) -> upright portrait=(%d,%d) sensor=%s\n",
            rx, ry, x, y, tostring(S.last_orientation)))
    end
    local id = next_tracking_id
    next_tracking_id = next_tracking_id + 1
    active_fingers[finger] = id
    genEmuEvent(C.EV_ABS, C.ABS_MT_SLOT, finger)
    genEmuEvent(C.EV_ABS, C.ABS_MT_TRACKING_ID, id)
    genEmuEvent(C.EV_ABS, C.ABS_MT_POSITION_X, x)
    genEmuEvent(C.EV_ABS, C.ABS_MT_POSITION_Y, y)
    genEmuEvent(C.EV_SYN, C.SYN_REPORT, 0)
end

local function fingerMove(finger, x, y)
    if not active_fingers[finger] then return end
    x, y = toLogical(x, y)
    genEmuEvent(C.EV_ABS, C.ABS_MT_SLOT, finger)
    genEmuEvent(C.EV_ABS, C.ABS_MT_POSITION_X, x)
    genEmuEvent(C.EV_ABS, C.ABS_MT_POSITION_Y, y)
    genEmuEvent(C.EV_SYN, C.SYN_REPORT, 0)
end

local function fingerUp(finger, x, y)
    if not active_fingers[finger] then return end
    x, y = toLogical(x, y)
    active_fingers[finger] = nil
    genEmuEvent(C.EV_ABS, C.ABS_MT_SLOT, finger)
    genEmuEvent(C.EV_ABS, C.ABS_MT_TRACKING_ID, -1)
    genEmuEvent(C.EV_ABS, C.ABS_MT_POSITION_X, x)
    genEmuEvent(C.EV_ABS, C.ABS_MT_POSITION_Y, y)
    genEmuEvent(C.EV_SYN, C.SYN_REPORT, 0)
end

local function handleEvent(ev)
    local t = ev.type
    if t == SDL_MOUSEBUTTONDOWN then
        local b = ev.button
        if b.which < MAX_FINGERS then fingerDown(b.which, b.x, b.y) end
    elseif t == SDL_MOUSEMOTION then
        local m = ev.motion
        if m.which < MAX_FINGERS then fingerMove(m.which, m.x, m.y) end
    elseif t == SDL_MOUSEBUTTONUP then
        local b = ev.button
        if b.which < MAX_FINGERS then fingerUp(b.which, b.x, b.y) end
    elseif t == SDL_ACTIVEEVENT then
        if ev.active.gain == 0 then
            genEmuEvent(C.EV_MSC, S.MSC_HIDE, 0)
        else
            genEmuEvent(C.EV_MSC, S.MSC_SHOW, 0)
        end
    elseif t == SDL_VIDEOEXPOSE then
        genEmuEvent(C.EV_MSC, S.MSC_SHOW, 0)
    elseif t == SDL_QUIT then
        genEmuEvent(C.EV_MSC, S.MSC_QUIT, 0)
    end
end

local event = ffi.new("SDL12_Event")

-- Tilt sensor. PDL queues sensor events, so drain them and keep only the latest reading.
local sensor_event = ffi.new("uint8_t[128]")
local sensor_type = ffi.cast("int32_t *", sensor_event)
local last_orientation = nil
S.last_orientation = nil
local next_sensor_poll = 0

local function pollOrientation(now)
    if not S.has_orientation or now < next_sensor_poll then return end
    next_sensor_poll = now + SENSOR_POLL_MS

    local latest
    for _ = 1, 32 do
        ffi.fill(sensor_event, 128)
        PDL.PDL_PollSensor(PDL_SENSOR_ORIENTATION, sensor_event)
        if sensor_type[0] ~= PDL_SENSOR_ORIENTATION then break end
        latest = sensor_type[1]
    end

    -- Only act on poses we know how to show (not face up / face down / unknown), and only on changes.
    -- The very first reading counts as a change, which sets the initial rotation at startup.
    local mode = latest and ORIENTATION_TO_MODE[latest]
    if mode and latest ~= last_orientation then
        last_orientation = latest
        S.last_orientation = latest
        if touch_debug then
            io.stderr:write(string.format("touch-debug: sensor orientation -> %d (rotation mode %d)\n", latest, mode))
        end
        genEmuEvent(C.EV_MSC, S.MSC_GYRO, mode)
    end
end

--- Wait for input. Same contract as ffi/SDL3.lua's waitForEvent:
--   returns true, <array of events>   when there is something to handle,
--   returns false, C.ETIME            on timeout,
--   returns false, C.EINTR            when woken without anything actionable.
-- @param sec  seconds part of the timeout (nil = wait indefinitely)
-- @param usec microseconds part of the timeout
function S.waitForEvent(sec, usec)
    inputQueue = {}

    local timeout_ms = sec and math.ceil((sec * 1000000 + usec) / 1000) or nil
    local start = SDL.SDL_GetTicks()
    while true do
        -- Drain everything pending in one go, so a burst of touch moves becomes one batch.
        while SDL.SDL_PollEvent(event) ~= 0 do handleEvent(event) end
        local now = SDL.SDL_GetTicks()
        pollOrientation(now)
        if #inputQueue > 0 then return true, inputQueue end

        local waited = now - start
        if timeout_ms and waited >= timeout_ms then
            return false, C.ETIME
        end
        SDL.SDL_Delay(timeout_ms and math.min(POLL_MS, timeout_ms - waited) or POLL_MS)
    end
end

return S
