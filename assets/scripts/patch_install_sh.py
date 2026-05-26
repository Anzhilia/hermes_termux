#!/usr/bin/env python3
"""
Patch hermes-agent install.sh for Android PRoot compatibility.

Usage: python3 patch_install_sh.py <proxy_prefix> [install_sh_path]

Rewrites install.sh to:
1. Replace git clone/pull/checkout with tarball download
2. Replace uv pip install (source build) with pip install from PyPI (wheel)
3. Skip browser (Playwright) install
4. Optionally prefix GitHub URLs with a proxy
"""
import sys
import re

def main():
    proxy = sys.argv[1] if len(sys.argv) > 1 else ""
    path = sys.argv[2] if len(sys.argv) > 2 else "/tmp/install.sh"

    with open(path) as f:
        code = f.read()

    tarball_url = proxy + "https://github.com/NousResearch/hermes-agent/archive/refs/heads/main.tar.gz"

    # 1. Replace the git clone/update block (if [ -d .git ] ... fi)
    #    with a simple tarball download.
    tarball_block = (
        '    # Download hermes-agent via tarball (git not supported by proxy)\n'
        '    log_info "Downloading hermes-agent via tarball..."\n'
        '    TARBALL_URL="' + tarball_url + '"\n'
        '    rm -rf "$INSTALL_DIR"\n'
        '    mkdir -p "$INSTALL_DIR"\n'
        '    curl -fsSL --connect-timeout 30 --max-time 300 "$TARBALL_URL" -o /tmp/hermes-agent.tar.gz || { log_error "Failed to download tarball"; exit 1; }\n'
        '    tar xzf /tmp/hermes-agent.tar.gz -C "$INSTALL_DIR" --strip-components=1 || { log_error "Failed to extract tarball"; exit 1; }\n'
        '    rm -f /tmp/hermes-agent.tar.gz\n'
        '    log_success "hermes-agent downloaded and extracted"\n'
    )

    lines = code.split("\n")
    result = []
    i = 0
    replaced = False
    while i < len(lines):
        line = lines[i]
        # Detect start of the git clone/update block
        if not replaced and ".git" in line and "INSTALL_DIR" in line and ("if" in line or "[" in line):
            depth = 0
            j = i
            while j < len(lines):
                s = lines[j].strip()
                if re.match(r"if\b", s) or ("[" in s and "then" in s):
                    depth += 1
                if s == "fi" or s.startswith("fi ") or s.endswith("fi"):
                    depth -= 1
                    if depth <= 0:
                        break
                j += 1
            for bl in tarball_block.strip().split("\n"):
                result.append(bl)
            i = j + 1
            replaced = True
            continue
        result.append(line)
        i += 1
    code = "\n".join(result)

    # 2. Remove any remaining git clone/pull/checkout lines (safety net)
    lines2 = code.split("\n")
    result2 = []
    for line in lines2:
        s = line.strip()
        if "git clone" in s or "git pull" in s:
            continue
        if "git checkout" in s and "BRANCH" in s:
            continue
        result2.append(line)
    code = "\n".join(result2)

    # 3. Replace uv/pip source installs with PyPI wheel install
    lines3 = code.split("\n")
    result3 = []
    for line in lines3:
        s = line.strip()
        if "uv pip install" in s and ("hermes" in s or "INSTALL_DIR" in s or "-e" in s or "." in s):
            result3.append('    log_info "Installing hermes-agent from PyPI (pre-compiled wheel)..."')
            result3.append('    "$PIP_PYTHON" -m pip install hermes-agent --break-system-packages 2>&1 || { log_error "pip install hermes-agent failed"; exit 1; }')
            continue
        if "pip install -e" in s and ("." in s or "termux" in s):
            result3.append('    log_info "Installing hermes-agent from PyPI (pre-compiled wheel)..."')
            result3.append('    "$PIP_PYTHON" -m pip install hermes-agent --break-system-packages 2>&1 || { log_error "pip install hermes-agent failed"; exit 1; }')
            continue
        result3.append(line)
    code = "\n".join(result3)

    # 4. Replace GitHub URLs with proxy
    if proxy:
        code = code.replace("https://github.com/", proxy + "https://github.com/")
        code = code.replace("git@github.com:", proxy + "https://github.com/")
        code = code.replace("https://astral.sh/uv/install.sh", proxy + "https://astral.sh/uv/install.sh")
        # Clean up double proxy prefix
        dbl = proxy + proxy
        while dbl in code:
            code = code.replace(dbl, proxy)

    with open(path, "w") as f:
        f.write(code)
    print("PATCHED")

if __name__ == "__main__":
    main()
