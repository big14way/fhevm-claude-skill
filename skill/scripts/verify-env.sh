#!/usr/bin/env bash
#
# scripts/verify-env.sh — the VERIFY layer of the Zama FHEVM skill
#
# Operational form of CR-2 (grep-before-trust). Run once at the start of
# every FHEVM session. Confirms:
#   1. Node.js is installed and at a compatible (even) major version
#   2. The FHEVM packages are installed at skill-compatible versions
#   3. Every canonical symbol the skill references is present in the
#      installed library
#   4. Known-removed symbols from stale API versions are absent in user
#      code (warns; does not fail)
#
# Exits 0 if every required check passes. Exits 1 if any required check
# fails — agents must stop and report the failure to the user before
# proceeding, per the SKILL.md verification gate.
#
# Output format: one line per check, prefixed with a status token.
#   VERIFIED   — check passed
#   MISSING    — required item absent; triggers non-zero exit
#   WARN       — optional or heuristic finding; does not fail
#   INFO       — version or metadata line
#
# Not silent on success: agents and humans both benefit from seeing the
# full verified state, because "VERIFIED" next to a specific symbol name
# is itself pedagogical — it teaches the agent what the canonical names are.

set -u  # treat unset variables as errors
# NOT set -e: we want to report every check, not bail on the first failure.

# -----------------------------------------------------------------------------
# Resolve the project root (the directory containing node_modules/).
# Script may be invoked from any directory; find node_modules/ by walking up.
# -----------------------------------------------------------------------------

find_project_root() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/node_modules" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

PROJECT_ROOT="$(find_project_root)"
if [ -z "${PROJECT_ROOT:-}" ]; then
    echo "MISSING  node_modules/ not found in \$PWD or any parent directory"
    echo ""
    echo "Run 'npm install' in your project root before running this script."
    exit 1
fi

FHEVM_SOL="$PROJECT_ROOT/node_modules/@fhevm/solidity/lib/FHE.sol"
TYPES_SOL="$PROJECT_ROOT/node_modules/encrypted-types/EncryptedTypes.sol"
FHEVM_PLUGIN="$PROJECT_ROOT/node_modules/@fhevm/hardhat-plugin"

echo "INFO     project root: $PROJECT_ROOT"
echo ""

# -----------------------------------------------------------------------------
# Track failures. We still run every check so the output is complete,
# but we exit non-zero at the end if anything required failed.
# -----------------------------------------------------------------------------

FAILURES=0

fail() {
    FAILURES=$((FAILURES + 1))
    echo "MISSING  $1"
}

ok() {
    echo "VERIFIED $1"
}

warn() {
    echo "WARN     $1"
}

info() {
    echo "INFO     $1"
}

# -----------------------------------------------------------------------------
# Check 1 — Node.js version.
# Hardhat does not support odd-numbered Node majors (v21, v23) per Zama docs.
# Minimum supported: v20. Current LTS range: v20, v22, v24.
# -----------------------------------------------------------------------------

echo "=== Node.js ==="

if ! command -v node >/dev/null 2>&1; then
    fail "node not installed or not on PATH"
else
    NODE_VERSION="$(node --version)"                         # v22.19.0
    NODE_MAJOR="$(echo "$NODE_VERSION" | sed 's/v//' | cut -d. -f1)"
    info "node version: $NODE_VERSION"

    if [ "$NODE_MAJOR" -lt 20 ]; then
        fail "node major version $NODE_MAJOR is below minimum (20)"
    elif [ $((NODE_MAJOR % 2)) -ne 0 ]; then
        fail "node major version $NODE_MAJOR is odd; Hardhat requires even-numbered Node versions"
    else
        ok "node version compatible (>=20, even)"
    fi
fi

echo ""

# -----------------------------------------------------------------------------
# Check 2 — FHEVM package installation and versions.
# Skill targets @fhevm/solidity >=0.10 and @fhevm/hardhat-plugin >=0.4.
# -----------------------------------------------------------------------------

echo "=== FHEVM packages ==="

# @fhevm/solidity
SOLIDITY_PKG="$PROJECT_ROOT/node_modules/@fhevm/solidity/package.json"
if [ ! -f "$SOLIDITY_PKG" ]; then
    fail "@fhevm/solidity not installed"
else
    SOLIDITY_VERSION="$(grep '"version":' "$SOLIDITY_PKG" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')"
    info "@fhevm/solidity version: $SOLIDITY_VERSION"

    SOLIDITY_MAJOR="$(echo "$SOLIDITY_VERSION" | cut -d. -f1)"
    SOLIDITY_MINOR="$(echo "$SOLIDITY_VERSION" | cut -d. -f2)"

    # Accept 0.10+, 0.11+, or any 1.x+.
    if [ "$SOLIDITY_MAJOR" -ge 1 ]; then
        ok "@fhevm/solidity version compatible"
    elif [ "$SOLIDITY_MAJOR" -eq 0 ] && [ "$SOLIDITY_MINOR" -ge 10 ]; then
        ok "@fhevm/solidity version compatible (>=0.10)"
    else
        fail "@fhevm/solidity version $SOLIDITY_VERSION is below skill-supported minimum (0.10)"
    fi
fi

# @fhevm/hardhat-plugin
PLUGIN_PKG="$PROJECT_ROOT/node_modules/@fhevm/hardhat-plugin/package.json"
if [ ! -f "$PLUGIN_PKG" ]; then
    fail "@fhevm/hardhat-plugin not installed"
else
    PLUGIN_VERSION="$(grep '"version":' "$PLUGIN_PKG" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')"
    info "@fhevm/hardhat-plugin version: $PLUGIN_VERSION"

    PLUGIN_MAJOR="$(echo "$PLUGIN_VERSION" | cut -d. -f1)"
    PLUGIN_MINOR="$(echo "$PLUGIN_VERSION" | cut -d. -f2)"

    if [ "$PLUGIN_MAJOR" -ge 1 ]; then
        ok "@fhevm/hardhat-plugin version compatible"
    elif [ "$PLUGIN_MAJOR" -eq 0 ] && [ "$PLUGIN_MINOR" -ge 4 ]; then
        ok "@fhevm/hardhat-plugin version compatible (>=0.4)"
    else
        fail "@fhevm/hardhat-plugin version $PLUGIN_VERSION is below skill-supported minimum (0.4)"
    fi
fi

echo ""

# -----------------------------------------------------------------------------
# Check 3a — Encrypted types in EncryptedTypes.sol.
#
# The encrypted types (euint*, ebool, eaddress, and their externalEuint*
# variants) are declared in a separate transitive dependency, `encrypted-types`
# (authored by the Confidential Token Association), NOT in @fhevm/solidity.
# FHE.sol imports from it:
#
#   import "encrypted-types/EncryptedTypes.sol";
#
# Greping FHE.sol for `type euint32` returns empty, which is correct — FHE.sol
# uses these types everywhere but declares none of them. See footgun log entry
# on library layout for the author's own trip through this wall.
#
# Note on the grep pattern below: `function allow(` and similar patterns
# include a literal `(`. This script uses `grep -q` (basic regex mode), in
# which `(` is literal, not a group-open metacharacter. Do not migrate these
# to `grep -E` without escaping.
# -----------------------------------------------------------------------------

echo "=== Encrypted types in encrypted-types/EncryptedTypes.sol ==="

if [ ! -f "$TYPES_SOL" ]; then
    fail "EncryptedTypes.sol not found at expected path: $TYPES_SOL"
    warn "this file is provided by the transitive dependency 'encrypted-types'; run 'npm install' to restore it"
    echo ""
else
    check_type() {
        local symbol="$1"
        local context="${2:-}"
        if grep -q "$symbol" "$TYPES_SOL"; then
            if [ -n "$context" ]; then
                ok "$symbol  ($context)"
            else
                ok "$symbol"
            fi
        else
            fail "$symbol not found in EncryptedTypes.sol"
        fi
    }

    # Encrypted unsigned integer types — the workhorses.
    # The library also provides 8-bit-increment sizes (euint24, euint40, etc.)
    # and signed (eint*) / byte-array (ebytes*) variants; this script covers
    # the canonical handful the skill teaches. See references/encrypted-types.md
    # for the full inventory.
    check_type "type euint8"     "encrypted uint8"
    check_type "type euint16"    "encrypted uint16"
    check_type "type euint32"    "encrypted uint32"
    check_type "type euint64"    "encrypted uint64"
    check_type "type euint128"   "encrypted uint128"
    check_type "type euint256"   "encrypted uint256 (limited ops)"
    check_type "type ebool"      "encrypted bool"
    check_type "type eaddress"   "encrypted address"

    # External input variants (for FHE.fromExternal)
    check_type "type externalEuint32" "encrypted input from frontend"
    check_type "type externalEbool"   "encrypted bool input"

    echo ""
fi

# -----------------------------------------------------------------------------
# Check 3b — Canonical functions in FHE.sol.
# FHE.sol declares the FHE library functions (allow, fromExternal, add, etc.)
# and re-exports types from encrypted-types via its `import` at the top.
# -----------------------------------------------------------------------------

echo "=== Canonical functions in FHE.sol ==="

if [ ! -f "$FHEVM_SOL" ]; then
    fail "FHE.sol not found at expected path: $FHEVM_SOL"
    echo ""
else
    check_function() {
        local symbol="$1"
        local context="${2:-}"
        if grep -q "$symbol" "$FHEVM_SOL"; then
            if [ -n "$context" ]; then
                ok "$symbol  ($context)"
            else
                ok "$symbol"
            fi
        else
            fail "$symbol not found in FHE.sol"
        fi
    }

    check_function "function fromExternal"        "convert external input to euint"
    check_function "function asEuint32"           "trivially encrypt a plaintext"
    check_function "function allowThis"           "grant contract ACL on handle"
    check_function "function allow("              "grant address ACL on handle"
    check_function "function allowTransient"      "transaction-scoped grant"
    check_function "function isSenderAllowed"     "check caller ACL"
    check_function "function makePubliclyDecryptable" "mark handle for public decrypt (v0.10+)"
    check_function "function select"              "branchless encrypted conditional"

    echo ""
fi

# -----------------------------------------------------------------------------
# Check 4 — Absence of removed symbols in FHE.sol.
# These are pre-v0.9 APIs the skill teaches the agent to refuse. If any of
# them unexpectedly reappears in a future library version, the skill's
# anti-pattern list needs revising — so we confirm they're still absent.
# -----------------------------------------------------------------------------

echo "=== Removed symbols absent from FHE.sol ==="

if [ -f "$FHEVM_SOL" ]; then
    check_absent() {
        local symbol="$1"
        local reason="$2"
        if grep -q "$symbol" "$FHEVM_SOL"; then
            warn "$symbol IS PRESENT in FHE.sol — skill's anti-pattern for this symbol may be stale (reason cited: $reason)"
        else
            ok "$symbol absent ($reason)"
        fi
    }

    check_absent "requestDecryption"  "removed in v0.9, replaced by makePubliclyDecryptable"
    check_absent "DecryptionOracle"   "removed in v0.9 consolidation"
    check_absent "onDecryptionResult" "gateway callback pattern removed in v0.9"

    # Config symbol absence is checked differently — it's in ZamaConfig.sol, not FHE.sol
    CONFIG_SOL="$PROJECT_ROOT/node_modules/@fhevm/solidity/config/ZamaConfig.sol"
    if [ -f "$CONFIG_SOL" ]; then
        if grep -q "contract SepoliaConfig" "$CONFIG_SOL" || grep -q "abstract contract SepoliaConfig" "$CONFIG_SOL"; then
            warn "SepoliaConfig IS PRESENT in ZamaConfig.sol — skill's anti-pattern may be stale"
        else
            ok "SepoliaConfig absent (consolidated into ZamaEthereumConfig in v0.10)"
        fi

        if grep -q "ZamaEthereumConfig" "$CONFIG_SOL"; then
            ok "ZamaEthereumConfig present in ZamaConfig.sol"
        else
            fail "ZamaEthereumConfig not found in ZamaConfig.sol (expected v0.10+ canonical config)"
        fi
    else
        warn "ZamaConfig.sol not found at expected path; skipping config symbol checks"
    fi

    echo ""
fi

# -----------------------------------------------------------------------------
# Check 5 — Canonical symbols in the hardhat-plugin.
# These are the fhevm.* helpers tests rely on.
# -----------------------------------------------------------------------------

echo "=== Canonical symbols in @fhevm/hardhat-plugin ==="

if [ ! -d "$FHEVM_PLUGIN" ]; then
    # Already failed above, skip silently.
    :
else
    # The plugin's built output location varies; search both common paths.
    PLUGIN_SEARCH_DIRS=()
    [ -d "$FHEVM_PLUGIN/_types" ] && PLUGIN_SEARCH_DIRS+=("$FHEVM_PLUGIN/_types")
    [ -d "$FHEVM_PLUGIN/_cjs" ]   && PLUGIN_SEARCH_DIRS+=("$FHEVM_PLUGIN/_cjs")
    [ -d "$FHEVM_PLUGIN/dist" ]   && PLUGIN_SEARCH_DIRS+=("$FHEVM_PLUGIN/dist")
    [ -d "$FHEVM_PLUGIN/src" ]    && PLUGIN_SEARCH_DIRS+=("$FHEVM_PLUGIN/src")

    if [ "${#PLUGIN_SEARCH_DIRS[@]}" -eq 0 ]; then
        warn "could not locate built output in @fhevm/hardhat-plugin; skipping plugin symbol checks"
    else
        check_plugin_symbol() {
            local symbol="$1"
            local context="${2:-}"
            local found=0
            for dir in "${PLUGIN_SEARCH_DIRS[@]}"; do
                if grep -rq "$symbol" "$dir" 2>/dev/null; then
                    found=1
                    break
                fi
            done
            if [ $found -eq 1 ]; then
                if [ -n "$context" ]; then
                    ok "$symbol  ($context)"
                else
                    ok "$symbol"
                fi
            else
                fail "$symbol not found in plugin ($(IFS=', '; echo "${PLUGIN_SEARCH_DIRS[*]}"))"
            fi
        }

        check_plugin_symbol "publicDecryptEuint" "public decrypt in tests"
        check_plugin_symbol "userDecryptEuint"   "user decrypt via EIP-712"
        check_plugin_symbol "createEncryptedInput" "build encrypted test inputs"
        check_plugin_symbol "FhevmType"          "type enum for decrypt helpers"
    fi

    echo ""
fi

# -----------------------------------------------------------------------------
# Check 6 — User code anti-pattern scan (informational, never fails).
# Quick sweep of the user's contracts/ and test/ directories for known-stale
# patterns. This is a preview of scripts/lint-antipatterns.js; we include a
# minimal version here so the verify gate catches problems before the agent
# writes new code against a contaminated codebase.
# -----------------------------------------------------------------------------

echo "=== User code scan (stale patterns) ==="

USER_CODE_DIRS=()
[ -d "$PROJECT_ROOT/contracts" ] && USER_CODE_DIRS+=("$PROJECT_ROOT/contracts")
[ -d "$PROJECT_ROOT/test" ]      && USER_CODE_DIRS+=("$PROJECT_ROOT/test")

if [ "${#USER_CODE_DIRS[@]}" -eq 0 ]; then
    info "no contracts/ or test/ directory found; skipping user-code scan"
else
    stale_scan() {
        local pattern="$1"
        local label="$2"
        local matches
        matches="$(grep -rln "$pattern" "${USER_CODE_DIRS[@]}" 2>/dev/null || true)"
        if [ -n "$matches" ]; then
            warn "$label found in user code — refuse to copy this pattern, offer to fix:"
            echo "$matches" | sed 's/^/           /'
        else
            ok "no $label in user code"
        fi
    }

    stale_scan "FHE.requestDecryption" "pre-v0.9 requestDecryption"
    stale_scan "DecryptionOracle"      "pre-v0.9 DecryptionOracle"
    stale_scan "onDecryptionResult"    "pre-v0.9 gateway callback"
    stale_scan "import {SepoliaConfig" "pre-v0.10 SepoliaConfig import"
fi

echo ""

# -----------------------------------------------------------------------------
# Exit with summary
# -----------------------------------------------------------------------------

echo "==============================="
if [ "$FAILURES" -eq 0 ]; then
    echo "VERIFIED — all required checks passed"
    echo ""
    echo "Safe to proceed with FHEVM work in this environment."
    exit 0
else
    echo "FAILED — $FAILURES required check(s) missing"
    echo ""
    echo "Do not write FHEVM code against this environment until the missing"
    echo "items are resolved. Report the failures to the user and ask how to"
    echo "proceed (update dependencies, use different version, etc.)."
    exit 1
fi
