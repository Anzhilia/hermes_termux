#!/bin/bash
# ============================================================================
# Hermes Agent Installer — PRoot/Android optimized (v2)
# ============================================================================
# Simplified installer for PRoot on Android.
# Uses pip wheel install (pre-compiled) instead of editable install.
# PyPI proxy is separate from GitHub proxy (--pypi-mirror).
#
# Usage:
#   bash install.sh [--proxy PREFIX] [--version VERSION] [--pypi-mirror URL]
#
# Options:
#   --proxy PREFIX      GitHub proxy prefix (for install.sh download, NOT PyPI)
#   --version VERSION   Specific version (default: latest)
#   --pypi-mirror URL   PyPI mirror URL (e.g. https://mirrors.aliyun.com/pypi/simple/)
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

log_info()    { echo -e "${CYAN}→${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }

PROXY_PREFIX=""
VERSION="latest"
PYPI_MIRROR=""
INSTALL_DIR="/usr/local/lib/hermes-agent"

while [[ $# -gt 0 ]]; do
    case $1 in
        --proxy)       PROXY_PREFIX="$2"; shift 2 ;;
        --version)     VERSION="$2"; shift 2 ;;
        --pypi-mirror) PYPI_MIRROR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: install.sh [--proxy PREFIX] [--version VERSION] [--pypi-mirror URL]"
            exit 0 ;;
        *) shift ;;
    esac
done

# Build pip flags for mirror
PIP_FLAGS=""
if [ -n "$PYPI_MIRROR" ]; then
    # Extract host for --trusted-host
    MIRROR_HOST=$(echo "$PYPI_MIRROR" | sed -E 's|https?://([^/]+).*|\1|')
    PIP_FLAGS="-i $PYPI_MIRROR"
    if [ -n "$MIRROR_HOST" ]; then
        PIP_FLAGS="$PIP_FLAGS --trusted-host $MIRROR_HOST"
    fi
fi

unset PYTHONPATH 2>/dev/null || true
unset PYTHONHOME 2>/dev/null || true
export UV_NO_CONFIG=1

echo ""
echo -e "${CYAN}${BOLD}┌─────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}${BOLD}│       ⚕ Hermes Agent Installer (PRoot v2)       │${NC}"
echo -e "${CYAN}${BOLD}└─────────────────────────────────────────────────┘${NC}"
echo ""

# ============================================================
# Step 1: Ensure Python3 + pip
# ============================================================
log_info "Checking Python3..."
if ! command -v python3 &>/dev/null; then
    log_info "Installing Python3 via apt..."
    # Kill stale apt-get/dpkg + clean locks
    killall apt-get dpkg 2>/dev/null || true
    sleep 1
    rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null || true
    dpkg --configure -a 2>/dev/null || true
    apt-get update -qq 2>/dev/null
    apt-get install -y --no-install-recommends python3 python3-pip python3-venv 2>/dev/null
fi

if ! command -v python3 &>/dev/null; then
    log_error "Python3 not available"
    exit 1
fi
log_success "Python: $(python3 --version 2>&1)"

# Ensure pip
python3 -m pip --version &>/dev/null || {
    log_info "Installing pip..."
    apt-get install -y --no-install-recommends python3-pip python3-venv 2>/dev/null || true
}

# ============================================================
# Step 2: Ensure curl + tar
# ============================================================
for tool in curl tar; do
    if ! command -v "$tool" &>/dev/null; then
        log_info "Installing $tool..."
        apt-get install -y --no-install-recommends "$tool" 2>/dev/null || true
    fi
done

# ============================================================
# Step 3: Resolve version from PyPI
# ============================================================
PYPI_JSON_URL="https://pypi.org/pypi/hermes-agent/json"
if [ "$VERSION" = "latest" ]; then
    log_info "Fetching latest version from PyPI..."
    RESOLVED=$(curl -fsSL "$PYPI_JSON_URL" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['version'])" 2>/dev/null || true)
    if [ -z "$RESOLVED" ]; then
        log_error "Failed to fetch version from PyPI"
        exit 1
    fi
    VERSION="$RESOLVED"
fi
log_success "Version: $VERSION"

# ============================================================
# Step 4: Create virtual environment (official recommendation)
# ============================================================
VENV_DIR="/root/.hermes/hermes-agent/venv"
log_info "Creating virtual environment at $VENV_DIR..."
mkdir -p /root/.hermes
python3 -m venv "$VENV_DIR" 2>&1 || {
    log_warn "venv creation failed, trying with --without-pip..."
    python3 -m venv --without-pip "$VENV_DIR" 2>&1
    # Bootstrap pip into venv
    "$VENV_DIR/bin/python" -m ensurepip 2>/dev/null || \
    "$VENV_DIR/bin/python" <(curl -fsSL https://bootstrap.pypa.io/get-pip.py) 2>/dev/null || true
}
if [ ! -x "$VENV_DIR/bin/python" ]; then
    log_error "Failed to create venv"
    exit 1
fi
log_success "Virtual environment created: $VENV_DIR"
log_success "Python: $("$VENV_DIR/bin/python" --version 2>&1)"

# ============================================================
# Step 5: Install hermes-agent into venv
# ============================================================
log_info "Installing hermes-agent ${VERSION} into venv..."

# Upgrade pip inside venv (use python -m pip for robustness)
"$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel 2>&1 || true

# Install from PyPI package into venv
INSTALL_OK=false
if "$VENV_DIR/bin/python" -m pip install "hermes-agent==$VERSION" $PIP_FLAGS 2>&1; then
    INSTALL_OK=true
    log_success "Installed hermes-agent $VERSION from PyPI"
elif "$VENV_DIR/bin/python" -m pip install "hermes-agent" $PIP_FLAGS 2>&1; then
    INSTALL_OK=true
    log_success "Installed hermes-agent (latest) from PyPI"
fi

if [ "$INSTALL_OK" != "true" ]; then
    log_error "pip install hermes-agent failed"
    log_info "Try using a PyPI mirror: --pypi-mirror https://mirrors.aliyun.com/pypi/simple/"
    exit 1
fi

# ============================================================
# Step 6: Ensure aiohttp (hermes dependency)
# ============================================================
log_info "Ensuring aiohttp is installed..."
"$VENV_DIR/bin/python" -c "import aiohttp" 2>/dev/null || {
    log_info "Installing aiohttp into venv..."
    "$VENV_DIR/bin/python" -m pip install aiohttp $PIP_FLAGS 2>&1 || true
}

# ============================================================
# Step 7: Create hermes command (wrapper script pointing to venv)
# ============================================================

# Ensure hermes_cli.__main__ exists so `python3 -m hermes_cli` works
log_info "Checking hermes_cli entry point..."
HERMES_PKG=$("$VENV_DIR/bin/python" -c "import hermes_cli; import os; print(os.path.dirname(hermes_cli.__file__))" 2>/dev/null)
if [ -n "$HERMES_PKG" ] && [ -d "$HERMES_PKG" ]; then
    if [ ! -f "$HERMES_PKG/__main__.py" ]; then
        cat > "$HERMES_PKG/__main__.py" << 'MAINPY'
from hermes_cli.main import main
main()
MAINPY
        log_success "Created $HERMES_PKG/__main__.py"
    else
        log_info "__main__.py already exists"
    fi
else
    log_warn "Could not find hermes_cli package directory"
fi

log_info "Creating hermes command..."
mkdir -p /usr/local/bin

# Create a wrapper script pointing to venv (official recommendation)
cat > /usr/local/bin/hermes << WRAPPER
#!/bin/sh
# Hermes Agent entry point (auto-generated by install.sh)
# Uses venv as recommended by official documentation
export HOME=/root
VENV="$VENV_DIR"
if [ -x "\$VENV/bin/python" ]; then
    exec "\$VENV/bin/python" -m hermes_cli "\$@"
fi
# Fallback to system python
unset PYTHONPATH 2>/dev/null
unset PYTHONHOME 2>/dev/null
exec python3 -m hermes_cli "\$@"
WRAPPER
chmod +x /usr/local/bin/hermes
log_success "hermes command created at /usr/local/bin/hermes (venv mode)"

# ============================================================
# Step 8: Verify
# ============================================================
log_info "Verifying installation..."
if /usr/local/bin/hermes --version >/dev/null 2>&1; then
    HERMES_VER=$(/usr/local/bin/hermes --version 2>/dev/null || echo "unknown")
    echo ""
    log_success "Hermes Agent $HERMES_VER installed successfully! (venv)"
elif "$VENV_DIR/bin/python" -m hermes_cli --version >/dev/null 2>&1; then
    HERMES_VER=$("$VENV_DIR/bin/python" -m hermes_cli --version 2>/dev/null || echo "unknown")
    echo ""
    log_success "Hermes Agent $HERMES_VER installed (venv, via python -m hermes_cli)"
else
    log_warn "hermes --version failed, but package was installed"
    log_info "Try running: $VENV_DIR/bin/python -m hermes_cli --version"
fi
echo ""
