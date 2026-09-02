# Falls back to no color (rather than crashing under `set -e`, which every
# script sourcing this runs under) when there's no terminal to style for --
# e.g. piped through something that doesn't allocate a tty.
YELLOW=$(tput setaf 3 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
NC=$(tput sgr0 2>/dev/null || true)