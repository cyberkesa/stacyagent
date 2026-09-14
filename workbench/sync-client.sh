#!/bin/bash
# Syncs the canonical Stacy Agent RuntimeClient (TypeScript, zero vscode imports)
# from the Stacy Agent repo into the Code-OSS fork. The fork never edits the copy;
# all changes happen in the Stacy Agent repo, then re-sync + recompile.
#
# Usage: workbench/sync-client.sh [--fork <path>] [--check]
#   --check verifies the fork copy is identical (for review/CI).
set -euo pipefail

FORK_ROOT="${STACYAGENT_FORK:-$HOME/stacyagent-workbench/code-oss}"
CHECK_ONLY=0
while [ $# -gt 0 ]; do
	case "$1" in
		--fork) FORK_ROOT="$2"; shift 2 ;;
		--check) CHECK_ONLY=1; shift ;;
		*) echo "usage: $0 [--fork <path>] [--check]" >&2; exit 2 ;;
	esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/client/stacyagentRuntimeClient.ts"
DEST="$FORK_ROOT/src/vs/platform/stacyagentRuntime/node/stacyagentRuntimeClient.ts"

if [ ! -f "$SRC" ]; then
	echo "canonical client not found: $SRC" >&2
	exit 1
fi
if [ "$CHECK_ONLY" = "1" ]; then
	if cmp -s "$SRC" "$DEST"; then
		echo "client in sync"
	else
		echo "client OUT OF SYNC: $SRC != $DEST" >&2
		exit 1
	fi
	exit 0
fi
mkdir -p "$(dirname "$DEST")"
cp "$SRC" "$DEST"
echo "synced: $SRC -> $DEST"
