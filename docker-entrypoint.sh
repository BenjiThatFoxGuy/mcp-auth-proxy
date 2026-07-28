#!/bin/bash
set -e

if [ -n "$NODE_VERSION" ]; then
  export NVM_DIR="/usr/local/nvm"
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm install "$NODE_VERSION"
  nvm use "$NODE_VERSION"
fi

exec /usr/local/bin/mcp-auth-proxy "$@"
