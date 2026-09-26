#!/bin/bash
set -euo pipefail

export NVM_DIR="/usr/local/nvm"
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"

target_version="${NODE_VERSION:-22}"
nvm use "$target_version" >/dev/null

resolved_version="$(node --version)"
case "$resolved_version" in
v"$target_version".* | v"$target_version")
    echo "docker-entrypoint: using Node.js $resolved_version (npx $(npx --version))" >&2
    ;;
*)
    echo "docker-entrypoint: requested NODE_VERSION=$target_version but 'nvm use' resolved node to $resolved_version on PATH" >&2
    exit 1
    ;;
esac

exec /usr/local/bin/mcp-auth-proxy "$@"
