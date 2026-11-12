-- Dev only (loaded by the -Dev toc): a window of SLLCM's own for /sllcm share debug output, so the channel
-- traffic stays out of chat whatever chat addon is in use (Daylight UI's chat box shows every window's lines
-- in its own tabs, so a chat window of ours wouldn't keep them apart).
--
-- /sllcm share debug window: on (debug lines go here) / show it again if closed / off (back to chat).
-- The close button only hides it: lines keep coming in. Drag the title to move it, the corner to size it.
-- Place, size and on/off are kept in SkyborneMarkerDB.debugWindow.

local _, ns = ...

local MAX_LINES = 2000
local MIN_W, MIN_H = 300, 120
local TITLE_H = 20

local frame, list

local function Saved()
  local db = ns.GetDB()
  if not db then return nil end
  if type(db.debugWindow) ~= "table" then db.debugWindow = {} end
  return db.debugWindow
end

local function Save()
  local s = Saved()
  if not (s and frame) then return end
  local point, _, relPoint, x, y = frame:GetPoint(1)
  s.point, s.relPoint, s.x, s.y = point, relPoint, x, y
  s.w, s.h = frame:GetWidth(), frame:GetHeight()
end

local function Build()
  if frame then return end
  local s = Saved() or {}
  frame = CreateFrame("Frame", "SLLCMDebugWindow", UIParent)
  frame:SetSize(s.w or 520, s.h or 260)
  frame:SetPoint(s.point or "CENTER", UIParent, s.relPoint or "CENTER", s.x or 0, s.y or 0)
  frame:SetFrameStrata("MEDIUM")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:SetResizable(true)
  if frame.SetResizeBounds then frame:SetResizeBounds(MIN_W, MIN_H) elseif frame.SetMinResize then frame:SetMinResize(MIN_W, MIN_H) end

  local bg = frame:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.75)

  -- title bar: drag to move
  local bar = CreateFrame("Frame", nil, frame)
  bar:SetPoint("TOPLEFT")
  bar:SetPoint("TOPRIGHT")
  bar:SetHeight(TITLE_H)
  local barBg = bar:CreateTexture(nil, "BACKGROUND")
  barBg:SetAllPoints()
  barBg:SetColorTexture(0.1, 0.25, 0.35, 0.9)
  local title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("LEFT", 6, 0)
  title:SetText("SLLCM debug")
  bar:EnableMouse(true)
  bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", function() frame:StartMoving() end)
  bar:SetScript("OnDragStop", function() frame:StopMovingOrSizing() Save() end)

  local close = CreateFrame("Button", nil, bar, "UIPanelCloseButton")
  close:SetSize(TITLE_H + 4, TITLE_H + 4)
  close:SetPoint("RIGHT", 2, 0)
  -- (OnHide would also fire for Alt+Z and logout: the close button says "hidden", nothing else)
  close:SetScript("OnClick", function() frame:Hide() local x = Saved() if x then x.hidden = true end end)

  local clear = CreateFrame("Button", nil, bar)
  clear:SetSize(40, TITLE_H)
  clear:SetPoint("RIGHT", close, "LEFT", -2, 0)
  local clearText = clear:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  clearText:SetPoint("CENTER")
  clearText:SetText("Clear")
  clear:SetScript("OnClick", function() list:Clear() end)

  -- the lines: mouse wheel scrolls, shift + wheel jumps to the top / bottom
  list = CreateFrame("ScrollingMessageFrame", nil, frame)
  list:SetPoint("TOPLEFT", 6, -(TITLE_H + 4))
  list:SetPoint("BOTTOMRIGHT", -6, 14)
  list:SetFontObject(ChatFontNormal)
  list:SetJustifyH("LEFT")
  list:SetMaxLines(MAX_LINES)
  list:SetFading(false)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(self, delta)
    if IsShiftKeyDown() then
      if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
    elseif delta > 0 then
      self:ScrollUp()
    else
      self:ScrollDown()
    end
  end)

  -- bottom-right corner: drag to size
  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(14, 14)
  grip:SetPoint("BOTTOMRIGHT", -1, 1)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() Save() end)

  if s.hidden then frame:Hide() end
end

local DW = {}
ns.DebugWindow = DW

-- A debug line: true if the window took it (it's on), false for chat.
function DW.Add(text)
  local s = Saved()
  if not (s and s.on) then return false end
  Build()
  list:AddMessage(text)
  return true
end

-- /sllcm share debug window
function DW.Toggle()
  local s = Saved()
  if not s then return end
  Build()
  if s.on and not frame:IsShown() then
    s.hidden = nil
    frame:Show()
    ns.Print("debug window shown")
  elseif s.on then
    s.on, s.hidden = nil, nil
    frame:Hide()
    ns.Print("debug window off: debug lines go to chat again")
  else
    s.on, s.hidden = true, nil
    frame:Show()
    ns.Print("debug window on: debug lines go there (close it to hide; this command again to turn it off)")
  end
end

-- after login: back as it was left
function DW.Restore()
  local s = Saved()
  if not (s and s.on) then return end
  Build() -- shown unless it was closed
end
