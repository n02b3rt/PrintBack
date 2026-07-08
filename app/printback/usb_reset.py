"""Windows-only USB device restart helper.

Calls ``pnputil /restart-device`` on the PnP device backing a given COM port.
This is the official Microsoft mechanism for cycling a USB device's driver
state without unplugging the cable, used as last-resort recovery when the
Windows USB stack reports "device not functioning" (typically after rapid
flash + reconnect cycles, or the kernel-side CDC bookkeeping just gives up).

Requirements:
- Windows 10 1809+ (pnputil ships with the OS)
- Administrator privileges (pnputil refuses non-admin device operations)
- PowerShell available on PATH (used to translate COM number -> PnP InstanceId)

Returns ``(False, reason)`` cleanly on every failure mode so the caller can
fall back to plain backoff without exception handling.
"""

from __future__ import annotations

import ctypes
import subprocess
import sys


def is_supported() -> bool:
    return sys.platform == "win32"


def is_admin() -> bool:
    if not is_supported():
        return False
    try:
        return ctypes.windll.shell32.IsUserAnAdmin() != 0  # type: ignore[attr-defined]
    except (OSError, AttributeError):
        return False


def _find_instance_id(com_port: str) -> str | None:
    """Locate the PnP InstanceId for the device backing ``com_port``.

    Two strategies, narrow → narrower. Only matches by the actual COM number
    in the device's FriendlyName so we never accidentally reset the wrong
    device when the user has multiple ESPs plugged in.

      1. With ``-PresentOnly``: fast path when device is functioning.
      2. Without ``-PresentOnly``: catches devices stuck in error state
         where Windows kept the registry entry but the driver detached.

    If the COM number has fully disappeared from the registry, returns None
    (user must replug; we have no safe way to identify the right device).
    """
    if not is_supported():
        return None
    ps_cmd = (
        "$ErrorActionPreference='SilentlyContinue';"
        f"$d = Get-PnpDevice -PresentOnly | Where-Object "
        f"{{ $_.FriendlyName -like '*({com_port})*' }} | Select-Object -First 1;"
        f"if (-not $d) {{ $d = Get-PnpDevice | Where-Object "
        f"{{ $_.FriendlyName -like '*({com_port})*' }} | Select-Object -First 1 }};"
        "if ($d) { $d.InstanceId }"
    )
    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", ps_cmd],
            capture_output=True, text=True, timeout=8,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    instance_id = result.stdout.strip().splitlines()[0] if result.stdout.strip() else ""
    return instance_id or None


def restart_device(com_port: str) -> tuple[bool, str]:
    """Attempt a software cycle of the USB device backing ``com_port``.

    Returns (success, human-readable status). On success the device should
    re-enumerate within ~2-5 seconds; caller should sleep before retrying.
    """
    if not is_supported():
        return False, "USB reset only available on Windows"
    if not is_admin():
        return False, "USB reset requires admin (right-click app -> Run as administrator)"

    instance_id = _find_instance_id(com_port)
    if not instance_id:
        return False, f"could not locate PnP device for {com_port}"

    try:
        result = subprocess.run(
            ["pnputil", "/restart-device", instance_id],
            capture_output=True, text=True, timeout=15,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f"pnputil failed to run: {e}"

    if result.returncode == 0:
        return True, "USB device restarted"
    detail = (result.stdout + result.stderr).strip().replace("\n", " ")[:120]
    return False, f"pnputil rc={result.returncode}: {detail or 'no output'}"
