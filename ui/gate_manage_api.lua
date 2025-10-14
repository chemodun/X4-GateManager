local ffi = require("ffi")
local C = ffi.C

ffi.cdef [[
  typedef uint64_t UniverseID;

  typedef struct {
    float x;
    float y;
    float z;
    float yaw;
    float pitch;
    float roll;
  } UIPosRot;

  UniverseID  GetPlayerID(void);
	UIPosRot    GetPositionalOffset(UniverseID positionalid, UniverseID spaceid);
  void        SpawnObjectAtPos(const char* macroname, UniverseID sectorid, UIPosRot offset);
	UniverseID  SpawnObjectAtPos2(const char* macroname, UniverseID sectorid, UIPosRot offset, const char* ownerid);
	void        SetObjectSectorPos(UniverseID objectid, UniverseID sectorid, UIPosRot offset);
  void        SetObjectForcedRadarVisible(UniverseID objectid, bool value);
  void        SetKnownTo(UniverseID componentid, const char* factionid);
  bool        IsComponentClass(UniverseID componentid, const char* classname);
  void        AddGateConnection(UniverseID gateid, UniverseID othergateid);
  void        RemoveGateConnection(UniverseID gateid, UniverseID othergateid);
	void        SetFocusMapComponent(UniverseID holomapid, UniverseID componentid, bool resetplayerpan);
	void        SetSelectedMapComponent(UniverseID holomapid, UniverseID componentid);
	void        SetSelectedMapComponents(UniverseID holomapid, UniverseID* componentids, uint32_t numcomponentids);
	bool        SetSofttarget(UniverseID componentid, const char*const connectionname);
	bool        FindMacro(const char* macroname);
	uint32_t    GetNumMacrosStartingWith(const char* partialmacroname);
	uint32_t    GetMacrosStartingWith(const char** result, uint32_t resultlen, const char* partialmacroname);
]]

local GateManageAPI = {
  playerId = 0,
  gatesTable = {},
  acceleratorsTable = {},
}

local Lib = require("extensions.sn_mod_support_apis.ui.Library")

local function debugTrace(message)
  local text = "Gate_Manage_API: " .. message
  if type(DebugError) == "function" then
    DebugError(text)
  else
    print(text)
  end
end

local function getPlayerId()
  local current = C.GetPlayerID()
  if current == nil or current == 0 then
    return
  end

  local converted = ConvertStringTo64Bit(tostring(current))
  if converted ~= 0 and converted ~= GateManageAPI.playerId then
    debugTrace("updating player_id to " .. tostring(converted))
    GateManageAPI.playerId = converted
  end
end

local function toUniverseId(value)
  if value == nil then
    return 0
  end

  if type(value) == "number" then
    return value
  end

  local idStr = tostring(value)
  if idStr == "" or idStr == "0" then
    return 0
  end

  return ConvertStringTo64Bit(idStr)
end

local function RevertAndApplyMapRotation()
  local pi = math.pi
  local twoPi = 2 * pi
  local menu = Lib.Get_Egosoft_Menu("MapMenu")
  debugTrace("MapMenu is " .. tostring(menu))
  if menu and menu.holomap and (menu.holomap ~= 0) then
    local mapstate = ffi.new("HoloMapState")
    C.GetMapState(menu.holomap, mapstate)
    debugTrace(string.format("MapState: pitch %f, yaw %f, roll %f", mapstate.offset.pitch, mapstate.offset.yaw,
      mapstate.offset.roll))
    -- modulo in Lua can be tricky with negatives, so use this pattern
    angle = (mapstate.offset.yaw + pi) % twoPi
    if angle > pi then
        angle = angle - twoPi
    end
    return angle
  else
    debugTrace("No MapMenu or holomap, returning pi" .. tostring(pi))
    return pi
  end
end

local function toPosRot(offset, rotation)
  local posRot = ffi.new("UIPosRot")
  if offset and type(offset) == "table" then
    posRot.x = offset.x or 0.0
    posRot.y = offset.y or 0.0
    posRot.z = offset.z or 0.0
    if rotation and type(rotation) == "table" then
      posRot.yaw = rotation.yaw or 0.0
      posRot.pitch = rotation.pitch or 0.0
      posRot.roll = rotation.roll or 0.0
    else
      posRot.yaw = RevertAndApplyMapRotation() * 180.0 / math.pi
      posRot.pitch = 0.0
      posRot.roll = 0.0
    end
  end
  return posRot
end

local function recordResult(data)
  debugTrace("recordResult called for command ".. tostring(data and data.command) .. " with result " .. tostring(data and data.result))
  if GateManageAPI.playerId ~= 0 then
    local payload = data or {}
    SetNPCBlackboard(GateManageAPI.playerId, "$GateManageAPIResult", payload)
    AddUITriggeredEvent("Gate_Manage_API", "CommandResult")
  end
end

local function reportError(data)
  local data = data or {}
  data.result = "error"
  recordResult(data)

  local message = "Gate_Manage_API error"
  if data.info then
    message = message .. ": " .. tostring(data.info)
  end
  if data.detail then
    message = message .. " (" .. tostring(data.detail) .. ")"
  end

  DebugError(message)
end

local function reportSuccess(data)
  data = data or {}
  data.result = "success"
  recordResult(data)
end


local function getArgs()
  if GateManageAPI.playerId == 0 then
    debugTrace("getArgs unable to resolve player id")
  else
    local list = GetNPCBlackboard(GateManageAPI.playerId, "$GateManageAPICommand")
    if type(list) == "table" then
      debugTrace("getArgs retrieved " .. tostring(#list) .. " entries from blackboard")
      local args = list[#list]
      SetNPCBlackboard(GateManageAPI.playerId, "$GateManageAPICommand", nil)
      return args
    elseif list ~= nil then
      debugTrace("getArgs received non-table payload of type " .. type(list))
    else
      debugTrace("getArgs found no blackboard entries for player " .. tostring(GateManageAPI.playerId))
    end
  end
  return nil
end

local function gate_destination_id(id)
  local destination = GetComponentData(id, "destination")
  if destination == nil then
    return 0
  end
  local destinationId = toUniverseId(destination)
  if destinationId == nil then
    return 0
  end
  return destinationId
end

local function gate_has_connection(id)
  return gate_destination_id(id) ~= 0
end

function GateManageAPI.CollectGateMacros()
  GateManageAPI.gatesTable = {}
  GateManageAPI.acceleratorsTable = {}
  local n = C.GetNumMacrosStartingWith("props_")
  if n > 0 then
    local buf = ffi.new("const char*[?]", n)
    n = C.GetMacrosStartingWith(buf, n, "props_")
    for i = 0, n - 1 do
      local macro = ffi.string(buf[i])
      if IsMacroClass(macro, "gate") then
        local name = GetMacroData(macro, "name")
        local icon = GetMacroData(macro, "icon")
        if (icon == "mapob_jumpgate" or icon == "mapob_transorbital_accelerator") then
          local macroEntry = { name = name, macro = macro, icon = icon }
          if icon == "mapob_transorbital_accelerator" then
            macroEntry.isAccelerator = true
            table.insert(GateManageAPI.acceleratorsTable, macroEntry)
          else
            macroEntry.isAccelerator = false
            table.insert(GateManageAPI.gatesTable, macroEntry)
          end
          debugTrace("Found gate macro: " .. macro .. " (" .. name .. "), isAccelerator=" .. tostring(macroEntry.isAccelerator))
        end
      end
    end
  end
  debugTrace("Collected " .. tostring(#GateManageAPI.gatesTable) .. " gate macros and " .. tostring(#GateManageAPI.acceleratorsTable) .. " accelerator macros")
end

function GateManageAPI.CreateGate(args)
  debugTrace("CreateGate called in sector " .. GetComponentData(args.sector, "macro"))
  local sector = toUniverseId(args.sector)
  local macroId = args.macroId
  if sector == 0 then
    args.info = "MissingSector"
    reportError(args)
    return
  end
  if not macroId or macroId == "" then
    args.info = "MissingMacro"
    reportError(args)
    return
  end

  if not C.FindMacro(macroId) then
    args.info = "InvalidMacro"
    args.detail = string.format("Macro not found: %s", macroId)
    reportError(args)
    return
  end

  if not IsMacroClass(macroId, "gate") then
    args.info = "InvalidMacroClass"
    args.detail = string.format("Macro is not a gate: %s", macroId)
    reportError(args)
    return
  end

  local menu = Lib.Get_Egosoft_Menu("MapMenu")
  debugTrace("MapMenu is " .. tostring(menu))
  if menu and menu.holomap and (menu.holomap ~= 0) then
    local mapstate = ffi.new("HoloMapState")
    C.GetMapState(menu.holomap, mapstate)
    debugTrace(string.format("MapState: pitch %f, yaw %f, roll %f", mapstate.offset.pitch, mapstate.offset.yaw,
      mapstate.offset.roll))
  end

  local posRot = nil
  if (args.getRotationFromMap) then
    posRot = toPosRot(args.offset, nil)
  else
    posRot = toPosRot(args.offset, args.rotation)
  end
  debugTrace(string.format("Spawning gate with macro %s at x=%f, y=%f, z=%f, yaw=%f, pitch=%f, roll=%f", macro, posRot.x, posRot.y,
    posRot.z, posRot.yaw, posRot.pitch, posRot.roll))
  local object = C.SpawnObjectAtPos2(macroId, sector, posRot, "ownerless")

  if object == nil then
    args.info = "SpawnFailed"
    reportError(args)
    return
  end
  C.SetKnownTo(object, "player")
  debugTrace("SpawnObjectAtPos returned object " .. GetComponentData(ConvertStringToLuaID(tostring(object)), "name"))

  args.info = "GateCreated"
  args.gate = ConvertStringToLuaID(tostring(object))
  reportSuccess(args)
end

function GateManageAPI.ConnectGates(args)
  local gateSource = toUniverseId(args.gateSource)
  local gateTarget = toUniverseId(args.gateTarget)

  if gateSource == 0 or gateTarget == 0 or gateSource == gateTarget then
    args.info = "InvalidGateIDs"
    reportError(args)
    return
  end

  if not C.IsComponentClass(gateSource, "gate") or not C.IsComponentClass(gateTarget, "gate") then
    args.info = "NotGate"
    reportError(args)
    return
  end

  if gate_has_connection(gateSource) or gate_has_connection(gateTarget) then
    args.info = "GateAlreadyConnected"
    reportError(args)
    return
  end

  local gateSourceIsAccelerator = GetComponentData(gateSource, "isaccelerator")
  local gateTargetIsAccelerator = GetComponentData(gateTarget, "isaccelerator")

  debugTrace(string.format("Gate source %s is accelerator: %s", tostring(gateSource), tostring(gateSourceIsAccelerator)))
  debugTrace(string.format("Gate target %s is accelerator: %s", tostring(gateTarget), tostring(gateTargetIsAccelerator)))

  if gateSourceIsAccelerator ~= gateTargetIsAccelerator then
    args.info = "IncompatibleGates"
    reportError(args)
    return
  end

  local sourceGateMacro = GetComponentData(gateSource, "macro")
  local sourceMacroIsAccelerator = GetMacroData(sourceGateMacro, "isaccelerator")

  debugTrace(string.format("Gate source macro %s is accelerator: %s", tostring(sourceGateMacro), tostring(sourceMacroIsAccelerator)))


  local sectorSource = GetComponentData(gateSource, "sector")
  local sectorTarget = GetComponentData(gateTarget, "sector")

  C.AddGateConnection(gateSource, gateTarget)
  local menu = Lib.Get_Egosoft_Menu("MapMenu")
  debugTrace("MapMenu is " .. tostring(menu))
  if menu and menu.holomap and (menu.holomap ~= 0) then
    menu.selectedcomponents = {}
  end
  debugTrace(string.format("Connected gates %s (%s) <-> %s (%s)", tostring(gateSource), sectorSource,
    tostring(gateTarget),
    sectorTarget))
  args.info = "GatesConnected"
  reportSuccess(args)
end

function GateManageAPI.DisconnectGate(args)
  local gateSource = toUniverseId(args.gateSource)
  local sectorSource = GetComponentData(gateSource, "sector")
  local gateTarget = toUniverseId(args.gateTarget)
  local sectorTarget = GetComponentData(gateTarget, "sector")

  if gateSource == 0 then
    args.info = "InvalidGateID"
    reportError(args)
    return
  end

  if not C.IsComponentClass(gateSource, "gate") then
    args.info = "NotGate"
    reportError(args)
    return
  end

  if gateTarget == 0 then
    args.info = "NotConnected"
    reportError(args)
    return
  end

  C.RemoveGateConnection(gateSource, gateTarget)

  debugTrace(string.format("Disconnected gate %s (%s) from %s (%s)", tostring(gateSource), sectorSource,
    tostring(gateTarget), sectorTarget))

  args.info = "GateDisconnected"
  reportSuccess(args)
end

function GateManageAPI.MarkGateOnMap(args)
  local gate = tostring(args.gate)
  if not gate or gate == "" then
    reportError({ info = "InvalidGateID" })
    return
  end

  local menu = Lib.Get_Egosoft_Menu("MapMenu")
  debugTrace("MapMenu is " .. tostring(menu) .. " for gate " .. gate)
  if menu and menu.holomap and (menu.holomap ~= 0) then
    menu.selectedcomponents = {}
    if (args.command == "unmark_gate") then
      args.info = "GateUnmarked"
    else
      args.info = "GateMarked"
      menu.selectedcomponents[gate] = true
    end
    menu.refreshInfoFrame()
  else
    args.info = "NoMap"
    reportError(args)
    return
  end

  reportSuccess(args)
end

function GateManageAPI.HandleCommand(_, _)
  local args = getArgs()
  if not args or type(args) ~= "table" then
    debugTrace("HandleCommand invoked without args or invalid args")
    reportError("missing_args")
    return
  end
  debugTrace("HandleCommand received command: " .. tostring(args.command))
  if args.command == "build_gate" then
    GateManageAPI.CreateGate(args)
  elseif args.command == "connect_gates" then
    GateManageAPI.ConnectGates(args)
  elseif args.command == "disconnect_gates" then
    GateManageAPI.DisconnectGate(args)
  elseif args.command == "mark_gate" or args.command == "unmark_gate" then
    GateManageAPI.MarkGateOnMap(args)
  elseif args.command == "get_macro_tables" then
    args.gates = GateManageAPI.gatesTable
    args.accelerators = GateManageAPI.acceleratorsTable
    reportSuccess(args)
  else
    debugTrace("HandleCommand received unknown command: " .. tostring(args.command))
    args.info = "UnknownCommand"
    reportError(args)
  end
end

function GateManageAPI.Init()
  getPlayerId()
  ---@diagnostic disable-next-line: undefined-global
  RegisterEvent("GateManageAPI.HandleCommand", GateManageAPI.HandleCommand)
  AddUITriggeredEvent("Gate_Manage_API", "Reloaded")
  GateManageAPI.CollectGateMacros()
end

Register_Require_With_Init("extensions.gate_manager.ui.gate_manager", GateManageAPI, GateManageAPI.Init)

return GateManageAPI
