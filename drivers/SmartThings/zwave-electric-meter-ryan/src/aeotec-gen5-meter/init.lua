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

--- @type st.zwave.CommandClass.Configuration
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version=1 })
local energyMeterDefaults = require "st.zwave.defaults.energyMeter"
local powerMeterDefaults = require "st.zwave.defaults.powerMeter"
--- @type st.zwave.CommandClass.Meter
local Meter = (require "st.zwave.CommandClass.Meter")({ version=3 })
--- @type st.zwave.CommandClass
local cc = require "st.zwave.CommandClass"
local capabilities = require "st.capabilities"
local log = require "log"

local AEOTEC_GEN5_FINGERPRINTS = {
  {mfr = 0x0086, prod = 0x0102, model = 0x005F},  -- Aeotec Home Energy Meter (Gen5) US
  {mfr = 0x0086, prod = 0x0002, model = 0x005F},  -- Aeotec Home Energy Meter (Gen5) EU
}

local function can_handle_aeotec_gen5_meter(opts, driver, device, ...)
  for _, fingerprint in ipairs(AEOTEC_GEN5_FINGERPRINTS) do
    if device:id_match(fingerprint.mfr, fingerprint.prod, fingerprint.model) then
      return true
    end
  end
  return false
end

local do_configure = function (self, device)
  device:send(Configuration:Set({parameter_number = 101, size = 4, configuration_value = 3}))   -- report total power in Watts and total energy in kWh...
  device:send(Configuration:Set({parameter_number = 102, size = 4, configuration_value = 0}))   -- disable group 2...
  device:send(Configuration:Set({parameter_number = 103, size = 4, configuration_value = 0}))   -- disable group 3...
  device:send(Configuration:Set({parameter_number = 111, size = 4, configuration_value = 300})) -- ...every 5 min
  device:send(Configuration:Set({parameter_number = 90, size = 1, configuration_value = 0}))    -- enabling automatic reports, disabled selective reporting...
  device:send(Configuration:Set({parameter_number = 13, size = 1, configuration_value = 0}))   -- disable CRC16 encapsulation
end

local function aeotec_gen5_meter_report_handler(driver, device, cmd)
  -- We got a meter report from the root node, so refresh all children
  -- endpoint 0 should have its reports dropped
  powerMeterDefaults.zwave_handlers[cc.METER][Meter.REPORT](driver, device, cmd)
  energyMeterDefaults.zwave_handlers[cc.METER][Meter.REPORT](driver, device, cmd)
  if cmd.args.scale == Meter.scale.electric_meter.KILOWATT_HOURS then
    local delta_energy = 0.0
    local current_power_consumption = device:get_latest_state("main", capabilities.powerConsumptionReport.ID, capabilities.powerConsumptionReport.powerConsumption.NAME)
    if current_power_consumption ~= nil then
      log.info(string.format("1-1 previous energy report value : %s ", tostring(current_power_consumption.energy)))
      delta_energy = math.max( cmd.args.meter_value * 1000 - current_power_consumption.energy, 0.0)
      if delta_energy > 0 then
        device:emit_event(
          capabilities.powerConsumptionReport.powerConsumption({ energy = cmd.args.meter_value * 1000, deltaEnergy = delta_energy })
        )
        log.info(string.format("1-2 normal case  %s : %s", tostring(cmd.args.meter_value * 1000), tostring(delta_energy)))
      elseif cmd.args.meter_value == 0 then
        log.info(string.format("1-3 meter_value is zero. meter reset case 0 : 0"))
        device:emit_event(
          capabilities.powerConsumptionReport.powerConsumption({ energy = 0, deltaEnergy = 0 })
        )
      else
        log.info(string.format("1-4 delta is zero. no event sent", tostring(delta_energy)))
      end
    else
      device:emit_event(
        capabilities.powerConsumptionReport.powerConsumption({ energy = cmd.args.meter_value * 1000, deltaEnergy = 0 })
      )
      log.info(string.format("1-5 First report %s : 0", tostring(cmd.args.meter_value * 1000)))
    end
  end
end

local aeotec_gen5_meter = {
  lifecycle_handlers = {
    doConfigure = do_configure
  },
  zwave_handlers = {
    [cc.METER] = {
      [Meter.REPORT] = aeotec_gen5_meter_report_handler
    }
  },
  NAME = "aeotec gen5 meter",
  can_handle = can_handle_aeotec_gen5_meter
}

return aeotec_gen5_meter
