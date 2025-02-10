local tmpCount = 0
local SuperWoWDetected = false
local SuperWoWExportLastRun = 0

  local function serialize(tbl, comp, name, spacing)
    local spacing = spacing or ""
    local match = nil
    local tname = ( spacing == "" and "" or "[\"" ) .. name .. ( spacing == "" and "" or "\"]" )
    local str = spacing .. tname .. " = {\n"

    for k, v in pairs(tbl) do
      if ( not comp or not comp[k] or comp[k] ~= tbl[k] ) then
        if type(v) == "table" then
          local result = serialize(tbl[k], comp and comp[k], k, spacing .. "  ")
          if result then
            match = true
            str = str .. result
          end
        elseif type(v) == "string" then
          match = true
          str = str .. spacing .. "  [\""..k.."\"] = \"".. string.gsub(v, "\\", "\\\\") .."\",\n"
        elseif type(v) == "number" then
          match = true
          str = str .. spacing .. "  [\""..k.."\"] = ".. string.gsub(v, "\\", "\\\\") ..",\n"
        end
      end
    end

    str = str .. spacing .. "}" .. ( spacing == "" and "" or "," ) .. "\n"
    return match and str or nil
  end

  local function compress(input)
    -- based on Rochet2's lzw compression
    if type(input) ~= "string" then
      return nil
    end
    local len = strlen(input)
    if len <= 1 then
      return "u"..input
    end

    local dict = {}
    for i = 0, 255 do
      local ic, iic = strchar(i), strchar(i, 0)
      dict[ic] = iic
    end
    local a, b = 0, 1

    local result = {"c"}
    local resultlen = 1
    local n = 2
    local word = ""
    for i = 1, len do
      local c = strsub(input, i, i)
      local wc = word..c
      if not dict[wc] then
        local write = dict[word]
        if not write then
          return nil
        end
        result[n] = write
        resultlen = resultlen + strlen(write)
        n = n+1
        if  len <= resultlen then
          return "u"..input
        end
        local str = wc
        if a >= 256 then
          a, b = 0, b+1
          if b >= 256 then
            dict = {}
            b = 1
          end
        end
        dict[str] = strchar(a,b)
        a = a+1
        word = c
      else
        word = wc
      end
    end
    result[n] = dict[word]
    resultlen = resultlen+strlen(result[n])
    n = n+1
    if  len <= resultlen then
      return "u"..input
    end
    return table.concat(result)
  end

  local function decompress(input)
    -- based on Rochet2's lzw compression
    if type(input) ~= "string" or strlen(input) < 1 then
      return nil
    end

    local control = strsub(input, 1, 1)
    if control == "u" then
      return strsub(input, 2)
    elseif control ~= "c" then
      return nil
    end
    input = strsub(input, 2)
    local len = strlen(input)

    if len < 2 then
      return nil
    end

    local dict = {}
    for i = 0, 255 do
      local ic, iic = strchar(i), strchar(i, 0)
      dict[iic] = ic
    end

    local a, b = 0, 1

    local result = {}
    local n = 1
    local last = strsub(input, 1, 2)
    result[n] = dict[last]
    n = n+1
    for i = 3, len, 2 do
      local code = strsub(input, i, i+1)
      local lastStr = dict[last]
      if not lastStr then
        return nil
      end
      local toAdd = dict[code]
      if toAdd then
        result[n] = toAdd
        n = n+1
        local str = lastStr..strsub(toAdd, 1, 1)
        if a >= 256 then
          a, b = 0, b+1
          if b >= 256 then
            dict = {}
            b = 1
          end
        end
        dict[strchar(a,b)] = str
        a = a+1
      else
        local str = lastStr..strsub(lastStr, 1, 1)
        result[n] = str
        n = n+1
        if a >= 256 then
          a, b = 0, b+1
          if b >= 256 then
            dict = {}
            b = 1
          end
        end
        dict[strchar(a,b)] = str
        a = a+1
      end
      last = code
    end
    return table.concat(result)
  end

  local function enc(to_encode)
    local index_table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local bit_pattern = ''
    local encoded = ''
    local trailing = ''

    for i = 1, string.len(to_encode) do
      local remaining = tonumber(string.byte(string.sub(to_encode, i, i)))
      local bin_bits = ''
      for i = 7, 0, -1 do
        local current_power = math.pow(2, i)
        if remaining >= current_power then
          bin_bits = bin_bits .. '1'
          remaining = remaining - current_power
        else
          bin_bits = bin_bits .. '0'
        end
      end
      bit_pattern = bit_pattern .. bin_bits
    end

    if mod(string.len(bit_pattern), 3) == 2 then
      trailing = '=='
      bit_pattern = bit_pattern .. '0000000000000000'
    elseif mod(string.len(bit_pattern), 3) == 1 then
      trailing = '='
      bit_pattern = bit_pattern .. '00000000'
    end

    local count = 0
    for i = 1, string.len(bit_pattern), 6 do
      local byte = string.sub(bit_pattern, i, i+5)
      local offset = tonumber(tonumber(byte, 2))
      encoded = encoded .. string.sub(index_table, offset+1, offset+1)
      count = count + 1
      if count >= 92 then
        encoded = encoded .. "\n"
        count = 0
      end
    end

    return string.sub(encoded, 1, -1 - string.len(trailing)) .. trailing
  end

  local function dec(to_decode)
    local index_table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local padded = gsub(to_decode,"%s", "")
    local unpadded = gsub(padded,"=", "")
    local bit_pattern = ''
    local decoded = ''

    to_decode = gsub(to_decode,"\n", "")
    to_decode = gsub(to_decode," ", "")

    for i = 1, string.len(unpadded) do
      local char = string.sub(to_decode, i, i)
      local offset, _ = string.find(index_table, char)
      if offset == nil then return nil end

      local remaining = tonumber(offset-1)
      local bin_bits = ''
      for i = 7, 0, -1 do
        local current_power = math.pow(2, i)
        if remaining >= current_power then
          bin_bits = bin_bits .. '1'
          remaining = remaining - current_power
        else
          bin_bits = bin_bits .. '0'
        end
      end

      bit_pattern = bit_pattern .. string.sub(bin_bits, 3)
    end

    for i = 1, string.len(bit_pattern), 8 do
      local byte = string.sub(bit_pattern, i, i+7)
      decoded = decoded .. strchar(tonumber(byte, 2))
    end

    local padding_length = string.len(padded)-string.len(unpadded)

    if (padding_length == 1 or padding_length == 2) then
      decoded = string.sub(decoded,1,-2)
    end

    return decoded
  end


local function ShaguInventorySuperWoWExport(table)

  -- Export via SuperWoW, if it's detected. No than once per min.
  if SuperWoWDetected then
    if GetTime() >= (SuperWoWExportLastRun + 60) then
      SuperWoWExportLastRun = GetTime()
      local compressed = enc(compress(serialize(table,nil, "exportedInventory")))
      ExportFile("ShaguInventory",compressed)
    end
  end
end


local frame=CreateFrame("Frame");
frame:RegisterEvent("VARIABLES_LOADED");
frame:SetScript("OnEvent",function(self,event,...)

	-- SuperWoW Detection & SuperWoW Import
	if GetPlayerBuffID and CombatLogAdd and SpellInfo then
		SuperWoWDetected = true
		local import = ImportFile("ShaguInventory")

      --Load the table
      local uncompressed = decompress(dec(import))
      local ImportConfig, error = loadstring(uncompressed)
      if not error and uncompressed ~= "" then
          ImportConfig()
          if not InventoryCounterDB then InventoryCounterDB = {} end
          for playerKey,containerVal in pairs(exportedInventory) do
              for containerKey,itemVal in pairs(containerVal) do
                  if not InventoryCounterDB[playerKey] then InventoryCounterDB[playerKey] = { } end
                  if not InventoryCounterDB[playerKey][containerKey] then InventoryCounterDB[playerKey][containerKey] = {} end
                  for itemKey,itemAmount in pairs(itemVal) do
                      InventoryCounterDB[playerKey][containerKey][itemKey] = itemAmount
                  end
              end
          end
      end
	end
end)

--Export the inventory on logout
local logoutframe=CreateFrame("Frame")
logoutframe:RegisterEvent("PLAYER_LOGOUT")
logoutframe:SetScript("OnEvent",function(self,event,...)
  ShaguInventorySuperWoWExport(InventoryCounterDB)
end)

function resetDB()
  InventoryCounterDB = {}
  InventoryCounterDB[currentCharacter] = {}
end

function InventoryCounter_UpdateBagsAndBank()
  --http://www.wowwiki.com/BagId
  position = "bank"
  InventoryCounterDB[currentCharacter][position] = nil
  InventoryCounterDB[currentCharacter][position] = {}
  for bag = -1, 10 do
    if(bag == 0) then
      position = "bag"
      InventoryCounterDB[currentCharacter][position] = nil
      InventoryCounterDB[currentCharacter][position] = {}
    end
    if(bag == 5) then
      position = "bank"
    end
    bagSize = GetContainerNumSlots(bag)
    if (bagSize>0) then
      for slot=1,bagSize do
        local _, itemCount = GetContainerItemInfo(bag, slot)
        local itemLink = GetContainerItemLink(bag, slot)
        if(itemCount and itemCount > 0) then
          local itemstring = string.sub(itemLink, string.find(itemLink, "%[")+1, string.find(itemLink, "%]")-1)
          tmpCount = InventoryCounterDB[currentCharacter][position][itemstring]
          if not tmpCount then
            InventoryCounterDB[currentCharacter][position][itemstring] = itemCount
          else
            InventoryCounterDB[currentCharacter][position][itemstring] = tmpCount + itemCount
          end
          ShaguInventorySuperWoWExport(InventoryCounterDB)
        end
      end
    end
  end
end
InventoryCounter_Tooltip = CreateFrame( "GameTooltip", "InventoryCounter_Tooltip", UIParent, "GameTooltipTemplate" )
InventoryCounterFrame = CreateFrame('Frame', "InventoryCounterFrame", GameTooltipTemplate)
InventoryCounterFrame:RegisterEvent("VARIABLES_LOADED")
InventoryCounterFrame:RegisterEvent("BAG_UPDATE")
InventoryCounterFrame:RegisterEvent("BANKFRAME_OPENED")
InventoryCounterFrame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
InventoryCounterFrame:SetScript("OnEvent", function (self)
    if event == "VARIABLES_LOADED" then
      currentCharacter = UnitName("player")
      if not InventoryCounterDB then
        InventoryCounterDB = {}
      end
      if not InventoryCounterDB[currentCharacter] then
        InventoryCounterDB[currentCharacter] = {}
      end
    end
    if event == "BAG_UPDATE" then
      position = "bag"
      InventoryCounterDB[currentCharacter][position] = nil
      InventoryCounterDB[currentCharacter][position] = {}
      for bag = 0, 4 do
        bagSize = GetContainerNumSlots(bag)
        if (bagSize>0) then
          for slot=1,bagSize do
            local _, itemCount = GetContainerItemInfo(bag, slot)
            local itemLink = GetContainerItemLink(bag, slot)
            if(itemCount and itemCount > 0) then
              local itemstring = string.sub(itemLink, string.find(itemLink, "%[")+1, string.find(itemLink, "%]")-1)
              tmpCount = InventoryCounterDB[currentCharacter][position][itemstring]
              if not tmpCount then
                InventoryCounterDB[currentCharacter][position][itemstring] = itemCount
              else
                InventoryCounterDB[currentCharacter][position][itemstring] = tmpCount + itemCount
              end
              ShaguInventorySuperWoWExport(InventoryCounterDB)
            end
          end
        end
      end
    end
    if event == "BANKFRAME_OPENED" then
      InventoryCounter_UpdateBagsAndBank()
    end
    if event == "PLAYERBANKSLOTS_CHANGED" then
      InventoryCounter_UpdateBagsAndBank()
    end
  end)
InventoryCounterFrameToolTip = CreateFrame( "Frame" , "InventoryCounterFrameToolTip", GameTooltip )
InventoryCounterFrameToolTip:SetScript("OnShow", function (self)
    if GameTooltip:GetAnchorType() == "ANCHOR_CURSOR" then return end
    if InventoryCounterDB then
      local lbl = getglobal("GameTooltipTextLeft1")
      if lbl then
        local itemName = lbl:GetText()
        local totalCount = 0
        local initLineAdded = nil
        for char,_ in pairs(InventoryCounterDB) do
          for slot,_ in pairs(InventoryCounterDB[char]) do
            local count = InventoryCounterDB[char][slot][itemName]
            if count then
              if not initLineAdded then
                GameTooltip:AddLine(" ", 0, 0, 0, 0)
                initLineAdded = true
              end
              totalCount = totalCount + count
              GameTooltip:AddDoubleLine(char .. " |cff556677[" .. slot .. "]", count, 0.65, 0.75, 0.85, 0.65, 0.75, 0.85)
            end
          end
        end
        if (totalCount>0) then
          GameTooltip:AddDoubleLine("Total:", totalCount, 0, 0.8, 1, 0, 0.8, 1)
        end
      end
    end
    GameTooltip:Show()
  end)
