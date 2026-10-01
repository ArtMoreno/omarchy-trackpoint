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


def main(args):
    with hypr_input.transaction():
        device = hypr_input.detect_device()
        # Validate the fields needed for the response before changing input.
        # A custom/unsupported sensitivity must not turn a successful disable
        # into an error response that leaves the panel showing the old state.
        current = hypr_input.get_value(device, 'sensitivity')
        if current is not None:
            float(current)
        enabled = is_enabled(device)
        arg = args[0] if args else None
        if arg in ('on', 'off', 'toggle'):
            enable = not enabled if arg == 'toggle' else arg == 'on'
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
        return {'value': value, 'device': device, 'enabled': is_enabled(device)}


if __name__ == '__main__':
    try:
        print(json.dumps(main(sys.argv[1:])))
    except Exception as exc:
        print(json.dumps({'error': str(exc)}))
        sys.exit(1)
