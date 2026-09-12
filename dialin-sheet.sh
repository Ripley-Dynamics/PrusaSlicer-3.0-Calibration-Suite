#!/usr/bin/env bash
# Dial-In Sheet for macOS and Linux: the same one-button startup as
# "Dial-In Sheet.cmd" on Windows, in the foreground. It updates the helper,
# installs the latest plugin, opens the dial-in sheet in your browser and
# starts PrusaSlicer. Ctrl-C stops the helper.
set -u
cd "$(dirname "$0")" || exit 1

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 was not found." >&2
    echo "Install Python 3 (python.org, or your package manager) and run this again." >&2
    exit 1
fi

exec python3 helper/dialin_helper.py --auto "$@"
