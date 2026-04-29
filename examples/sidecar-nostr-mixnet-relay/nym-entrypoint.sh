#!/bin/bash
# Nym SOCKS5 client entrypoint: initialize and run the client.
set -e

NYM_CLIENT_ID="${NYM_CLIENT_ID:-fips-nym-client}"
NYM_SOCKS5_PORT="${NYM_SOCKS5_PORT:-1080}"
NYM_SOCKS5_BIND="${NYM_SOCKS5_BIND:-0.0.0.0}"
NYM_SERVICE_PROVIDER="${NYM_SERVICE_PROVIDER:?NYM_SERVICE_PROVIDER is required}"

echo "========================================"
echo "  Nym SOCKS5 Client Sidecar"
echo "========================================"
echo "  Client ID:        ${NYM_CLIENT_ID}"
echo "  SOCKS5 listen:    ${NYM_SOCKS5_BIND}:${NYM_SOCKS5_PORT}"
echo "  Service provider: ${NYM_SERVICE_PROVIDER}"
echo "  Bandwidth:        free testnet mode"
echo "========================================"

# Initialize the client if not already done
if [ ! -d "${HOME}/.nym/socks5-clients/${NYM_CLIENT_ID}" ]; then
    echo ""
    echo ">>> Initializing Nym SOCKS5 client..."
    echo ""
    nym-socks5-client init \
        --id "${NYM_CLIENT_ID}" \
        --provider "${NYM_SERVICE_PROVIDER}" \
        --port "${NYM_SOCKS5_PORT}" \
        --host "${NYM_SOCKS5_BIND}"
    echo ""
    echo ">>> Nym client initialized successfully"
    echo ""
fi

echo ""
echo ">>> Starting Nym SOCKS5 client..."
echo ">>> Connecting to Nym mixnet (this may take 30-60 seconds)..."
echo "========================================"
echo ""

exec nym-socks5-client run \
    --id "${NYM_CLIENT_ID}" \
    --port "${NYM_SOCKS5_PORT}" \
    --host "${NYM_SOCKS5_BIND}"
