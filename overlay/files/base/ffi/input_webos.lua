-- Input backend for the HP TouchPad: SDL 1.2 mouse events -> fake Linux multitouch events.
-- Same shape as ffi/input_SDL3.lua; all the real work is in ffi/SDL1_2.lua.
local SDL = require("ffi/SDL1_2")

return {
    -- Video and input share one SDL setup, which framebuffer_webos opens.
    open = function() return SDL.open() end,
    waitForEvent = SDL.waitForEvent,
    -- NOPs:
    fakeTapInput = function() end,
    close = function() end,
    -- SDL_Quit is called by the framebuffer's close.
    closeAll = function() end,
    -- Tell the frontend that we're a custom implementation with no concept of paths/fds.
    is_ffi = true,
    MSC_GYRO = SDL.MSC_GYRO,
    MSC_QUIT = SDL.MSC_QUIT,
    MSC_HIDE = SDL.MSC_HIDE,
    MSC_SHOW = SDL.MSC_SHOW,
}
