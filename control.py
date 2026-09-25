#!/usr/bin/env python3
"""Read or set the TrackPoint pointer sensitivity, or switch the device off and on.

  control.py                  print {"value": <sensitivity>, "device": <name>, "enabled": <bool>}
  control.py <value>          set the sensitivity, from -1 (slower) to 1 (faster)
  control.py on|off|toggle    enable or disable the TrackPoint (buttons included)
"""
import json
import math
import sys

sys.dont_write_bytecode = True
import hypr_input  # noqa: E402


def is_enabled(device):
    # Hyprland's per-device default is enabled, so an absent key means on
    return hypr_input.get_value(device, 'enabled') is not False


try:
    device = hypr_input.detect_device()
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    if arg in ('on', 'off', 'toggle'):
        enable = not is_enabled(device) if arg == 'toggle' else arg == 'on'
        # true is Hyprland's default, so clear the setting rather than pin it
        hypr_input.set_values(device, {'enabled': None if enable else 'false'})
    elif arg is not None:
        value = float(arg)
        if not math.isfinite(value) or not -1 <= value <= 1:
            raise ValueError('Sensitivity must be between -1 and 1.')
        value = round(value, 2)
        # 0 is Hyprland's default, so clear the setting rather than pin it
        hypr_input.set_values(device, {'sensitivity': None if value == 0 else f'{value:.2f}'})
    current = hypr_input.get_value(device, 'sensitivity')
    value = float(current) if current is not None else 0.0
    print(json.dumps({'value': value, 'device': device, 'enabled': is_enabled(device)}))
except Exception as exc:
    print(json.dumps({'error': str(exc)}))
    sys.exit(1)
