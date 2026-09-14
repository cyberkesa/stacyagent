#!/bin/bash
# Builds the /Applications "Stacy Agent" launcher as a macOS applet.
#
# Background: double-clicking .build/electron/*.app opens a RAW Electron
# bundle (Electron welcome screen), because the Code-OSS workbench entry
# point is NOT the bare bundle — it is the bundle binary launched with the
# dev environment + repo root, exactly like ./scripts/code.sh does:
#   cd $ROOT && NODE_ENV=development VSCODE_DEV=1 VSCODE_CLI=1 ... \
#     ./.build/electron/<nameLong>.app/Contents/MacOS/<nameShort> [args]
#
# This script bakes those values (read live from product.json, so a
# rebrand only needs regeneration) into an AppleScript applet at
# /Applications/<nameLong>.app. Re-run after product renames.
set -euo pipefail

FORK_ROOT="${STACYAGENT_FORK:-$HOME/stacyagent-workbench/code-oss}"
APP_NAME="$(node -p "require('$FORK_ROOT/product.json').nameLong")"
EXE_NAME="$(node -p "require('$FORK_ROOT/product.json').nameShort")"
BIN="$FORK_ROOT/.build/electron/$APP_NAME.app/Contents/MacOS/$EXE_NAME"
DEST="/Applications/$APP_NAME.app"
LOG_FILE="/tmp/stacyagent-workbench-launch.log"

if [ ! -x "$BIN" ]; then
	echo "missing executable: $BIN (build the fork first)" >&2
	exit 1
fi

if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
	echo "refusing to overwrite non-symlink $DEST" >&2
	exit 1
fi
rm -f "$DEST"

STAGE="$(mktemp -d)"
cat > "$STAGE/launch.applescript" <<EOF
on run
	my launchStacyAgent({})
end run

on open theFiles
	my launchStacyAgent(theFiles)
end open

on launchStacyAgent(filesArg)
	set rootPath to "$FORK_ROOT"
	set codeBin to "$BIN"
	set logFile to "$LOG_FILE"
	set argsStr to ""
	repeat with f in filesArg
		set argsStr to argsStr & " " & quoted form of POSIX path of f
	end repeat
	do shell script "cd " & quoted form of rootPath & " && NODE_ENV=development VSCODE_DEV=1 VSCODE_CLI=1 ELECTRON_ENABLE_STACK_DUMPING=1 ELECTRON_ENABLE_LOGGING=1 " & quoted form of codeBin & " " & quoted form of rootPath & " --new-window " & argsStr & " >> " & quoted form of logFile & " 2>&1 & echo \$!"
end launchStacyAgent
EOF

osacompile -o "$DEST" "$STAGE/launch.applescript"
rm -rf "$STAGE"
echo "launcher ready: $DEST"
echo "entrypoint: $BIN"
