-- Editor-safe PNG decoding for player-art imports. No engine or native modules.
-- https://www.w3.org/TR/PNG/ (IHDR/PLTE/tRNS, filtering and sample packing).
-- Defold 1.14 editor zlib.inflate accepts the complete zlib stream: concatenate
-- IDAT payloads without stripping their two-byte header or Adler-32 trailer.
-- decode(bytes, {name=path, inflate=fn}) returns unpremultiplied RGBA, top row first.
local M = {}
local byte, char, floor = string.byte, string.char, math.floor
local CHANNELS = {[0]=1,[2]=3,[3]=1,[4]=2,[6]=4}
local SIGNATURE = "\137PNG\r\n\026\n"

local function u32(bytes, position)
    local a,b,c,d=byte(bytes,position,position+3)
    return ((a*256+b)*256+c)*256+d
end
local function u16(bytes, position)
    local a,b=byte(bytes,position,position+1)
    return a*256+b
end
local function paeth(a,b,c)
    local p=a+b-c
    local pa,pb,pc=math.abs(p-a),math.abs(p-b),math.abs(p-c)
    if pa<=pb and pa<=pc then return a end
    if pb<=pc then return b end
    return c
end

function M.decode(bytes, opts)
    opts=opts or {}
    local name=tostring(opts.name or "PNG image")
    local function check(condition, message)
        assert(condition,name..": "..message)
    end
    check(type(bytes)=="string" and bytes:sub(1,8)==SIGNATURE,"not a PNG file")
    local width,height,depth,kind,channels,palette,transparency
    local parts,position,ended,has_data={},9,false,false
    while position<=#bytes do
        check(position+11<=#bytes,"truncated PNG chunk")
        local length=u32(bytes,position)
        local chunk=bytes:sub(position+4,position+7)
        check(length<=#bytes-position-11,"truncated "..chunk.." chunk")
        local content=bytes:sub(position+8,position+7+length)
        if not width then check(chunk=="IHDR","IHDR must be the first chunk") end
        if chunk=="IHDR" then
            check(not width and length==13,"invalid IHDR chunk")
            width,height=u32(content,1),u32(content,5)
            depth,kind=byte(content,9,10)
            check(width>0 and height>0 and width<2147483648 and height<2147483648,"invalid image dimensions")
            check(depth~=16,"16-bit PNGs are not supported; re-export as 8-bit and non-interlaced")
            check(byte(content,13)==0,"interlaced PNGs are not supported; re-export as 8-bit and non-interlaced")
            channels=CHANNELS[kind]
            check(channels~=nil,"unsupported PNG colour type "..tostring(kind))
            check(depth==8 or ((kind==0 or kind==3) and (depth==1 or depth==2 or depth==4)),
                "unsupported PNG bit depth "..tostring(depth).."; re-export as 8-bit and non-interlaced")
            check(byte(content,11)==0 and byte(content,12)==0,"unsupported PNG compression or filter method")
        elseif chunk=="PLTE" then
            check(not has_data and not palette and length>=3 and length<=768 and length%3==0,"invalid PNG palette")
            palette=content
        elseif chunk=="tRNS" then
            check(not has_data and not transparency,"invalid PNG transparency chunk")
            check((kind==0 and length==2) or (kind==2 and length==6)
                or (kind==3 and palette and length>0 and length<=#palette/3),"invalid PNG transparency data")
            transparency=content
        elseif chunk=="IDAT" then
            has_data=true;parts[#parts+1]=content
        elseif chunk=="IEND" then
            check(length==0,"invalid IEND chunk");ended=true;break
        else
            -- Uppercase first letters mark critical chunks. Unknown ancillary
            -- chunks (colour profiles, text, etc.) do not alter stored samples.
            check(chunk:sub(1,1):match("%l")~=nil,"unsupported critical PNG chunk "..chunk)
        end
        position=position+length+12
    end
    check(ended and has_data,"missing PNG image data or IEND")
    check(kind~=3 or (palette and #palette/3<=2^depth),"missing or oversized PNG palette")
    local compressed=table.concat(parts)
    local inflate=opts.inflate or (zlib and zlib.inflate)
    check(type(inflate)=="function","PNG decompression is unavailable in this host")
    -- Keep failures attached to the actual source file, including native errors.
    local ok,raw=pcall(inflate,compressed)
    if not ok then check(false,"cannot decompress PNG data: "..tostring(raw)) end
    check(type(raw)=="string","cannot decompress PNG data: inflater returned no bytes")
    local stride=math.ceil(width*channels*depth/8)
    local bpp=math.max(1,math.ceil(channels*depth/8))
    check(#raw==(stride+1)*height,"PNG scanline data has the wrong length")
    local rows,previous={},{}
    local transparent_g=kind==0 and transparency and u16(transparency,1)
    local transparent_r=kind==2 and transparency and u16(transparency,1)
    local transparent_b=kind==2 and transparency and u16(transparency,5)
    local transparent_green=kind==2 and transparency and u16(transparency,3)
    local levels=2^depth
    for y=1,height do
        local start=(y-1)*(stride+1)+1
        local filter=byte(raw,start)
        check(filter<=4,"unsupported PNG scanline filter "..tostring(filter))
        local row,text={},{}
        for i=1,stride do
            local value=byte(raw,start+i)
            local a,b,c=row[i-bpp] or 0,previous[i] or 0,previous[i-bpp] or 0
            if filter==1 then value=value+a
            elseif filter==2 then value=value+b
            elseif filter==3 then value=value+floor((a+b)/2)
            elseif filter==4 then value=value+paeth(a,b,c) end
            value=value%256;row[i]=value;text[i]=char(value)
        end
        if kind==6 then rows[y]=table.concat(text)
        else
            local pixels={}
            for x=0,width-1 do
                if kind==0 or kind==3 then
                    local bit=x*depth
                    local sample=floor(row[floor(bit/8)+1]/2^(8-depth-bit%8))%levels
                    if kind==3 then
                        check(sample<#palette/3,"pixel refers to a missing palette entry")
                        local r,g,b=byte(palette,sample*3+1,sample*3+3)
                        pixels[x+1]=char(r,g,b,transparency and byte(transparency,sample+1) or 255)
                    else
                        local grey=sample*255/(levels-1)
                        pixels[x+1]=char(grey,grey,grey,sample==transparent_g and 0 or 255)
                    end
                elseif kind==2 then
                    local i=x*3+1;local r,g,b=row[i],row[i+1],row[i+2]
                    pixels[x+1]=char(r,g,b,r==transparent_r and g==transparent_green and b==transparent_b and 0 or 255)
                else
                    local i=x*2+1;local grey=row[i]
                    pixels[x+1]=char(grey,grey,grey,row[i+1])
                end
            end
            rows[y]=table.concat(pixels)
        end
        previous=row
    end
    return {width=width,height=height,type="rgba",buffer=table.concat(rows)}
end
return M
