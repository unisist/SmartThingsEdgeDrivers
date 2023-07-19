local capabilities = require "st.capabilities"
local log = require "log"
local clusters = require "st.matter.generated.zap_clusters"
local MatterDriver = require "st.matter.driver"
local lua_socket = require "socket"
local device_lib = require "st.device"

local START_BUTTON_PRESS = "__start_button_press"
local TIMEOUT_THRESHOLD = 10 --arbitrary timeout
local HELD_THRESHOLD = 1
-- this is the number of buttons for which we have a static profile already made
local STATIC_PROFILE_SUPPORTED = {2, 4, 8}

local ENDPOINT_TO_COMPONENT_MAP = "__endpoint_to_component_map"

-- These are essentially storing the supported features of a given endpoint
-- TODO: add an is_feature_supported_for_endpoint function to matter.device that takes an endpoint
local EMULATE_HELD = "__emulate_held" -- for MSR devices we can emulate this on the software side
local MULTI_BUTTON = "__multi_button" -- for multi-press devices, only trigger an event on a multi-button complete
local INITIAL_PRESS_ONLY = "__initial_press_only" -- for devices that support MS, but not MSR

--helper function to create liste of multi press values
local function create_multi_list(size)
  local list = {"pushed", "double"}
  for i=3, size do
    table.insert(list, string.format("pushed_%dx", i))
  end
  return list
end

local function contains(array, value)
  for _, element in ipairs(array) do
    if element == value then
      return true
    end
  end
  return false
end

local function get_field_for_endpoint(device, field, endpoint)
  return device:get_field(string.format("%s_%d", field, endpoint))
end

local function set_field_for_endpoint(device, field, endpoint, value, persist)
  device:set_field(string.format("%s_%d", field, endpoint), value, {persist = persist})
end

local function init_press(device, endpoint)
  set_field_for_endpoint(device, START_BUTTON_PRESS, endpoint, lua_socket.gettime(), false)
end

local function emulate_held_event(device, ep)
  local now = lua_socket.gettime()
  local press_init = get_field_for_endpoint(device, START_BUTTON_PRESS, ep) or now -- if we don't have an init time, assume instant release
  if (now - press_init) < TIMEOUT_THRESHOLD then
    if (now - press_init) > HELD_THRESHOLD then
      device:emit_event_for_endpoint(ep, capabilities.button.button.held({state_change = true}))
    else
      device:emit_event_for_endpoint(ep, capabilities.button.button.pushed({state_change = true}))
    end
  end
  set_field_for_endpoint(device, START_BUTTON_PRESS, ep, nil, false)
end

--end of helper functions
--------------------------------------------------------------------------

local function endpoint_to_component(device, ep)
  local map = device:get_field(ENDPOINT_TO_COMPONENT_MAP) or {}
  if map[ep] and device.profile.components[map[ep]] then
    return map[ep]
  end
  return "main"
end

local function component_to_endpoint(device, component_name)
  local map = device:get_field(ENDPOINT_TO_COMPONENT_MAP) or {}
  for ep, component in pairs(map) do
    if component == component_name then return ep end
  end
end

local function find_child(parent, ep_id)
  return parent:get_child_by_parent_assigned_key(string.format("%02X", ep_id))
end

local function device_init(driver, device)
  if device.network_type == device_lib.NETWORK_TYPE_MATTER then
    device:subscribe()
    device:set_find_child(find_child)
    device:set_endpoint_to_component_fn(endpoint_to_component)
    device:set_component_to_endpoint_fn(component_to_endpoint)
  end
end

local function device_added(driver, device)
  if device.network_type ~= device_lib.NETWORK_TYPE_CHILD then
    local MS = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.MOMENTARY_SWITCH})
    -- local LS = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.LATCHING_SWITCH})

    -- find the default/main endpoint, the device with the lowest EP that supports MS
    table.sort(MS)
    local main_endpoint = device.MATTER_DEFAULT_ENDPOINT
    if #MS > 0 then
      main_endpoint = MS[1] -- the endpoint matching to the non-child device
      if MS[1] == 0 then main_endpoint = MS[2] end -- we shouldn't hit this, but just in case
    end

    local MSR = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.MOMENTARY_SWITCH_RELEASE})
    local MSL = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.MOMENTARY_SWITCH_LONG_PRESS})
    local MSM = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.MOMENTARY_SWITCH_MULTI_PRESS})
    local battery_support = device:get_endpoints(clusters.PowerSource.ID)

    -- We have a static profile that will work for this number of buttons
    if contains(STATIC_PROFILE_SUPPORTED, #MS) then
      if #battery_support == 0 then
        device:try_update_metadata({profile = string.format("%d-button", #MS)})
      else
        device:try_update_metadata({profile = string.format("%d-button-battery", #MS)})
      end
    elseif #battery_support == 0 then
      -- a battery-less button/remote (either single or will use parent/child)
      device:try_update_metadata({profile = "button"})
    end

    -- At the moment, we're taking it for granted that all momentary switches only have 2 positions
    -- TODO: flesh this out for NumberOfPositions > 2
    local current_component_number = 2
    for _, ep in ipairs(MS) do -- for each momentary switch endpoint (including main)
      -- build the mapping of endpoints to components if we have a static profile (multi-component)
      if contains(STATIC_PROFILE_SUPPORTED, #MS) then
        local map = device:get_field(ENDPOINT_TO_COMPONENT_MAP) or {}
        if ep ~= main_endpoint then
          map[ep] = string.format("button%d", current_component_number)
          current_component_number = current_component_number + 1
        else
          map[ep] = "main"
        end
        device:set_field(ENDPOINT_TO_COMPONENT_MAP, map, {persist = true})
      else -- use parent/child
        if ep ~= main_endpoint then -- don't create a child device that maps to the main endpoint
          local name = string.format("%s %d", device.label, current_component_number)
          driver:try_create_device(
            {
              type = "EDGE_CHILD",
              label = name,
              profile = "child-button",
              parent_device_id = device.id,
              parent_assigned_child_key = string.format("%02X", ep),
              vendor_provided_label = name
            }
          )
          current_component_number = current_component_number + 1
        end
      end

      -- this ordering is important, as MSL & MSM devices must also support MSR
      if contains(MSL, ep) then
        device:emit_event_for_endpoint(ep, capabilities.button.supportedButtonValues({"pushed", "held"}, {visibility = {displayed = false}}))
      elseif contains(MSM, ep) then
        -- ask the device to tell us its max number of presses
        device:send(clusters.Switch.attributes.MultiPressMax:read(device, ep))
        set_field_for_endpoint(device, MULTI_BUTTON, ep, true, true)
      elseif contains(MSR, ep) then
        device:emit_event_for_endpoint(ep, capabilities.button.supportedButtonValues({"pushed", "held"}, {visibility = {displayed = false}}))
        set_field_for_endpoint(device, EMULATE_HELD, ep, true, true)
      else -- device only supports momentary switch, no release events
        device:emit_event_for_endpoint(ep, capabilities.button.supportedButtonValues({"pushed"}, {visibility = {displayed = false}}))
        set_field_for_endpoint(device, INITIAL_PRESS_ONLY, ep, true, true)
      end
      device:emit_event_for_endpoint(ep, capabilities.button.button.pushed({state_change = false}))
    end

    -- TODO: Solution for latching switches
    -- for _, ep in ipairs(LS) do
    --   local name = string.format("%s %d", device.label, ep)
    --   local child = driver:try_create_device(
    --     {
    --       type = "EDGE_CHILD",
    --       label = name,
    --       profile = "child-button",
    --       parent_device_id = device.id,
    --       parent_assigned_child_key = string.format("%02X", ep),
    --       vendor_provided_label = name
    --     }
    --   )
    --   -- Latching switches are switches that don't return to an idle position after being pressed.
    --   -- In that sense, they can be all sorts of things, like dials or radio buttons. This means
    --   -- they can have any number of states > 2. However, due to the current nature of our capabilities
    --   -- our ability to support the full range of options here is limited, so we will stick with
    --   -- up/down rocker switches (kind of).
    --   child:emit_event(capabilities.button.supportedButtonValues({"up","down"}, {visibility = {displayed = false}}))
    -- end

  end
end

--end of lifecyle handlers
----------------------------------------------------------------------------

-- initial press
local function initial_event_handler(driver, device, ib, response)
  if not get_field_for_endpoint(device, MULTI_BUTTON, ib.endpoint_id) then
    if get_field_for_endpoint(device, INITIAL_PRESS_ONLY, ib.endpoint_id) then
      device:emit_event_for_endpoint(ib.endpoint_id, capabilities.button.button.pushed({state_change = true}))
    elseif get_field_for_endpoint(device, EMULATE_HELD, ib.endpoint_id) then
      -- if our button doesn't differentiate between short and long holds, do it in code by keeping track of the press down time
      init_press(device, ib.endpoint_id)
    end
  end
end

-- if the devce distinguishes a long press event, it will always be a "held"
-- there's also a "long release" event, but this event is required to come first
local function long_press_event_handler(driver, device, ib, response)
  if not get_field_for_endpoint(device, MULTI_BUTTON, ib.endpoint_id) then
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.button.button.held({state_change = true}))
  end
end

-- short release event handler
local function short_release_event_handler(driver, device, ib, response)
  if not get_field_for_endpoint(device, MULTI_BUTTON, ib.endpoint_id) then
    if get_field_for_endpoint(device, EMULATE_HELD, ib.endpoint_id) then
      emulate_held_event(device, ib.endpoint_id)
    else
      device:emit_event_for_endpoint(ib.endpoint_id, capabilities.button.button.pushed({state_change = true}))
    end
  end
end


-- multi-press complete
local function multi_event_handler(driver, device, ib, response)
  -- in the case of multiple button presses
  -- emit number of times, multiple presses have been completed
  if ib.data then
    local press_value = ib.data.elements.total_number_of_presses_counted.value
    --capability only supports up to 6 presses
    if press_value < 7 then
      local button_event = capabilities.button.button.pushed({state_change = true})
      if press_value == 2 then
        button_event = capabilities.button.button.double({state_change = true})
      elseif press_value > 2 then
        button_event = capabilities.button.button(string.format("pushed_%dx", press_value), {state_change = true})
      end
      device:emit_event_for_endpoint(ib.endpoint_id, button_event)
    else
      log.info("Number of presses not supported by capability")
    end
  end
end

--end of event handlers
---------------------------------------------------------------------------
local function battery_percent_remaining_attr_handler(driver, device, ib, response)
  if ib.data.value then
    device:emit_event(capabilities.battery.battery(math.floor(ib.data.value / 2.0 + 0.5)))
  end
end

--need to find out max number of times a button can be pressed
local function max_press_handler(driver, device, ib, response)
  local max = ib.data.value or 1 --get max number of presses
  -- capability only supports up to 6 presses
  if max > 6 then
    log.info("Device supports more than 6 presses")
    max = 6
  end
  local values = create_multi_list(max)
  device:emit_event_for_endpoint(ib.endpoint_id, capabilities.button.supportedButtonValues(values, {visibility = {displayed = false}}))
end


-- end of attribute handlers
-- ------------------------------------------------------------------------
local matter_driver_template = {
  lifecycle_handlers = {init = device_init, added = device_added},
  matter_handlers = {
    attr = {
      [clusters.PowerSource.ID] = {
        [clusters.PowerSource.attributes.BatPercentRemaining.ID] = battery_percent_remaining_attr_handler
      },
      [clusters.Switch.ID] = {
        [clusters.Switch.attributes.MultiPressMax.ID] = max_press_handler,
      }
    },
    event = {
      [clusters.Switch.ID] = {
        [clusters.Switch.events.InitialPress.ID] = initial_event_handler,
        [clusters.Switch.events.LongPress.ID] = long_press_event_handler,
        [clusters.Switch.events.ShortRelease.ID] = short_release_event_handler,
        [clusters.Switch.events.MultiPressComplete.ID] = multi_event_handler,
      }
    },
  },
  subscribed_attributes = {
    [capabilities.battery.ID] = {
      clusters.PowerSource.attributes.BatPercentRemaining,
    },
  },
  subscribed_events = {
    [capabilities.button.ID] = {
      clusters.Switch.events.InitialPress,
      clusters.Switch.events.LongPress,
      clusters.Switch.events.ShortRelease,
      clusters.Switch.events.MultiPressComplete
    }
  },
}

local matter_driver = MatterDriver("matter-button", matter_driver_template)
matter_driver:run()
