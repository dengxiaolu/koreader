require "cache"

--[[
TODO: all these functions should probably be methods on Face objects
]]--

GlyphCache = Cache:new{
	max_memsize = 512*1024,
	current_memsize = 0,
	cache = {},
	-- this will hold the LRU order of the cache
	cache_order = {}
}

-- iterator over UTF8 encoded characters in a string
local function utf8Chars(input)
	local function read_next_glyph(input, pos)
		if string.len(input) < pos then return nil end
		local value = string.byte(input, pos)
		if bit.band(value, 0x80) == 0 then
			-- TODO: check valid ranges
			return pos+1, value, string.sub(input, pos, pos)
		elseif bit.band(value, 0xC0) == 0x80 -- invalid, continuation
		or bit.band(value, 0xF8) == 0xF8 -- 5-or-more byte sequence, illegal due to RFC3629
		then
			return pos+1, 0xFFFD, "\xFF\xFD"
		else
			local glyph, bytes_left
			if bit.band(value, 0xE0) == 0xC0 then
				glyph = bit.band(value, 0x1F)
				bytes_left = 1
			elseif bit.band(value, 0xF0) == 0xE0 then
				glyph = bit.band(value, 0x0F)
				bytes_left = 2
			elseif bit.band(value, 0xF8) == 0xF0 then
				glyph = bit.band(value, 0x07)
				bytes_left = 3
			else
				return pos+1, 0xFFFD, "\xFF\xFD"
			end
			if string.len(input) < (pos + bytes_left - 1) then
				return pos+1, 0xFFFD, "\xFF\xFD"
			end
			for i = pos+1, pos + bytes_left do
				value = string.byte(input, i)
				if bit.band(value, 0xC0) == 0x80 then
					glyph = bit.bor(bit.lshift(glyph, 6), bit.band(value, 0x3F))
				else
					return i+1, 0xFFFD, "\xFF\xFD"
				end
			end
			-- TODO: check for valid ranges here!
			return pos+bytes_left+1, glyph, string.sub(input, pos, pos+bytes_left)
		end
	end
	return read_next_glyph, input, 1
end

function getGlyph(face, charcode, bgcolor, fgcolor)
	if bgcolor == nil then bgcolor = 0.0 end
	if fgcolor == nil then fgcolor = 1.0 end
	local hash = "glyph|"..face.hash.."|"..charcode.."|"..bgcolor.."|"..fgcolor
	local glyph = GlyphCache:check(hash)
	if glyph then
		-- cache hit
		return glyph[1]
	end
	local rendered_glyph = face.ftface:renderGlyph(charcode, bgcolor, fgcolor)
	if face.ftface:checkGlyph(charcode) == 0 then
		for index, font in pairs(Font.fallbacks) do
			-- rescale face size by DPI since it will be scaled in getFace again
			local fb_face = Font:getFace(font, rescaleByDPI(face.size))
			if fb_face.ftface:checkGlyph(charcode) ~= 0 then
				rendered_glyph = fb_face.ftface:renderGlyph(charcode, bgcolor, fgcolor)
				DEBUG("fallback to font", font)
				break
			end
		end
	end
	if not rendered_glyph then
		DEBUG("error rendering glyph (charcode=", charcode, ") for face", face)
		return
	end
	glyph = CacheItem:new{rendered_glyph}
	glyph.size = glyph[1].bb:getWidth() * glyph[1].bb:getHeight() / 2 + 32
	GlyphCache:insert(hash, glyph)
	return rendered_glyph
end

function getSubTextByWidth(text, face, width, kerning)
	local pen_x = 0
	local prevcharcode = 0
	local char_list = {}
	for _, charcode, uchar in utf8Chars(text) do
		if pen_x < width then
			local glyph = getGlyph(face, charcode)
			if kerning and prevcharcode then
				local kern = face.ftface:getKerning(prevcharcode, charcode)
				pen_x = pen_x + kern
			end
			pen_x = pen_x + glyph.ax
			if pen_x <= width then
				prevcharcode = charcode
				table.insert(char_list, uchar)
			else
				break
			end
		end
	end
	return table.concat(char_list)
end

function sizeUtf8Text(x, width, face, text, kerning)
	if not text then
		DEBUG("sizeUtf8Text called without text");
		return
	end

	-- may still need more adaptive pen placement when kerning,
	-- see: http://freetype.org/freetype2/docs/glyphs/glyphs-4.html
	local pen_x = 0
	local pen_y_top = 0
	local pen_y_bottom = 0
	local prevcharcode = 0
	for _, charcode, uchar in utf8Chars(text) do
		if pen_x < (width - x) then
			local glyph = getGlyph(face, charcode)
			if kerning and (prevcharcode ~= 0) then
				pen_x = pen_x + (face.ftface):getKerning(prevcharcode, charcode)
			end
			pen_x = pen_x + glyph.ax
			pen_y_top = math.max(pen_y_top, glyph.t)
			pen_y_bottom = math.max(pen_y_bottom, glyph.bb:getHeight() - glyph.t)
			--DEBUG("ax:"..glyph.ax.." t:"..glyph.t.." r:"..glyph.r.." h:"..glyph.bb:getHeight().." w:"..glyph.bb:getWidth().." yt:"..pen_y_top.." yb:"..pen_y_bottom)
			prevcharcode = charcode
		end -- if pen_x < (width - x)
	end
	return { x = pen_x, y_top = pen_y_top, y_bottom = pen_y_bottom}
end

function renderUtf8Text(buffer, x, y, face, text, kerning, bgcolor, fgcolor)
	if not text then
		DEBUG("renderUtf8Text called without text");
		return 0
	end

	-- may still need more adaptive pen placement when kerning,
	-- see: http://freetype.org/freetype2/docs/glyphs/glyphs-4.html
	local pen_x = 0
	local prevcharcode = 0
	local buffer_width = buffer:getWidth()
	for _, charcode, uchar in utf8Chars(text) do
		if pen_x < buffer_width then
			local glyph = getGlyph(face, charcode, bgcolor, fgcolor)
			if kerning and (prevcharcode ~= 0) then
				pen_x = pen_x + face.ftface:getKerning(prevcharcode, charcode)
			end
			buffer:addblitFrom(
				glyph.bb,
				x + pen_x + glyph.l, y - glyph.t,
				0, 0,
				glyph.bb:getWidth(), glyph.bb:getHeight(), 1)
			pen_x = pen_x + glyph.ax
			prevcharcode = charcode
		end -- if pen_x < buffer_width
	end

	return pen_x
end
