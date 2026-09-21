-- Framebuffer for the HP TouchPad: an RGB565 blitbuffer that is copied to an SDL 1.2 software surface.
-- Modelled on ffi/framebuffer_SDL3.lua.
--
-- Rotation: the panel's buffer is landscape (1024x768, home button on the right). KOReader draws
-- into a blitbuffer and rotates it in software (BB:rotateAbsolute), so a rotation is just a different
-- mapping of the same physical memory. `is_always_portrait` makes KOReader's "upright" mode the
-- portrait one (the buffer rotated by 90 degrees), as it is on every other tablet-shaped device.
-- Touches are always reported in the upright portrait frame (see ffi/SDL1_2.lua); KOReader's gesture
-- detector applies the current rotation to them itself.
local BB = require("ffi/blitbuffer")
local SDL = require("ffi/SDL1_2")

local framebuffer = {
    is_always_portrait = true,
}

function framebuffer:init()
    SDL.open()
    if not SDL.is_rgb565 then
        error(string.format("TouchPad surface is %d bpp and not RGB565; this needs a converting blit", SDL.bpp))
    end
    self.w, self.h = SDL.w, SDL.h

    -- The panel is RGB565, so KOReader draws straight into the format it will be shown in.
    self.bb = BB.new(self.w, self.h, BB.TYPE_BBRGB16)
    self.bb:fill(BB.COLOR_WHITE)
    self:refreshFull(0, 0, self:getWidth(), self:getHeight())

    -- This applies the initial "always portrait" rotation to the blitbuffer.
    framebuffer.parent.init(self)
end

-- There is no e-ink waveform to choose here: every kind of refresh (full, partial, UI, fast...)
-- falls back to this one in the base class. We always push the whole frame.
function framebuffer:refreshFullImp(x, y, w, h)
    SDL.flip(self.full_bb or self.bb)
end

function framebuffer:close()
    SDL.close()
end

return require("ffi/framebuffer"):extend(framebuffer)
