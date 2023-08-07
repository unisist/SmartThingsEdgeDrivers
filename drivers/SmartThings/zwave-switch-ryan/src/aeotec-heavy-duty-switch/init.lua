-- Copyright 2022 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local st_device = require "st.device"
local utils = require "st.utils"
local capabilities = require "st.capabilities"
--- @type st.zwave.CommandClass
local cc = require "st.zwave.CommandClass"
--- @type st.zwave.CommandClass.Meter
local Meter = (require "st.zwave.CommandClass.Meter")({version = 3})
--- @type st.zwave.CommandClass.Basic
local Basic = (require "st.zwave.CommandClass.Basic")({ version = 1, strict = true })
--- @type st.zwave.CommandClass.SwitchBinary
local SwitchBinary = (require "st.zwave.CommandClass.SwitchBinary")({version = 2, strict = true })

local energyMeterDefaults = require "st.zwave.defaults.energyMeter"
local powerMeterDefaults = require "st.zwave.defaults.powerMeter"
local switchDefaults = require "st.zwave.defaults.switch"
local MULTI_METERING_SWITCH_CONFIGURATION_MAP = require "multi-metering-switch/multi_metering_switch_configurations"
local log = require "log"

local PARENT_ENDPOINT = 1

local MULTI_METERING_SWITCH_FINGERPRINTS = {
  {mfr = 0x0086, prod = 0x0003, model = 0x004E} -- Aeotec Heavy Duty Switch
}

local function can_handle_metering_switch(opts, driver, device, ...)
  log.info(string.format(" Aeotec Heavy Duty handle!!"))
  for _, fingerprint in ipairs(MULTI_METERING_SWITCH_FINGERPRINTS) do
    if device:id_match(fingerprint.mfr, fingerprint.prod, fingerprint.model) then
      return true
    end
  end
  return false
end


local function meter_report_handler(driver, device, cmd)
  -- We got a meter report from the root node, so refresh all children
  -- endpoint 0 should have its reports dropped
  log.info(string.format(" Aeotec Heavy Duty received!!"))
  log.info(string.format("1   %s", tostring(cmd.args.meter_value)))
  log.info(string.format("2   %s", tostring(cmd.args.meter_type)))
  log.info(string.format("3   %s", tostring(cmd.args.precision)))
  powerMeterDefaults.zwave_handlers[cc.METER][Meter.REPORT](driver, device, cmd)
  energyMeterDefaults.zwave_handlers[cc.METER][Meter.REPORT](driver, device, cmd)
  if cmd.args.scale == Meter.scale.electric_meter.KILOWATT_HOURS then
    local delta_energy = 0.0
    local current_power_consumption = device:get_latest_state("main", capabilities.powerConsumptionReport.ID, capabilities.powerConsumptionReport.powerConsumption.NAME)
    if current_power_consumption ~= nil then
      delta_energy = math.max( cmd.args.meter_value * 1000 - current_power_consumption.energy, 0.0)
      if delta_energy > 0 then
        device:emit_event(
          capabilities.powerConsumptionReport.powerConsumption({ energy = cmd.args.meter_value * 1000, deltaEnergy = delta_energy })
        )
        log.info(string.format("1-1   %s", tostring(delta_energy)))
      else
        log.info(string.format("1-1   %s delta is zero. no event sent", tostring(delta_energy)))
      end
    else
      device:emit_event(
        capabilities.powerConsumptionReport.powerConsumption({ energy = cmd.args.meter_value * 1000, deltaEnergy = delta_energy })
      )
      log.info(string.format("1-3   %s First report as delta = zero", tostring(delta_energy)))
    end
  end
end

-- Device appears to have some trouble with energy reset commands if the value is read too quickly
local function reset(driver, device, command)
  device.thread:call_with_delay(.5, function ()
    device:send_to_component(Meter:Reset({}), command.component)
  end)
  device.thread:call_with_delay(1.5, function()
    device:send_to_component(Meter:Get({scale = Meter.scale.electric_meter.KILOWATT_HOURS}), command.component)
  end)
end

local multi_metering_switch = {
  NAME = "Aeotec Heavy Duty metering switch",
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh
    },
    [capabilities.energyMeter.ID] = {
      [capabilities.energyMeter.commands.resetEnergyMeter.NAME] = reset
    }
  },
  zwave_handlers = {
    [cc.METER] = {
      [Meter.REPORT] = meter_report_handler
    }
  },
  can_handle = can_handle_metering_switch,
}

return multi_metering_switch
