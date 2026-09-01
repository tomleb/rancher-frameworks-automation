#!/usr/bin/env bash
# bump-remotedialer-proxy.sh — bumps remotedialer-proxy in a locally checked
# out rancher/rancher repo. Adapted from rancher/remotedialer-proxy's
# .github/workflows/scripts/release-against-rancher.sh, with these changes
# to fit the release-automation bumper's contract:
#
#  1. Single positional argument (new version). The chart-prefixed full
#     version is looked up at runtime from rancher/charts' index.yaml on
#     the branch named by the CHART_REF env var. The chart bump must
#     have merged into rancher/charts before this script runs (cascade
#     enforces that via the `order` edge).
#  2. No git operations. The bumper does one final `git add -A && git commit`
#     after every script in the bundle has run.
#  3. When the previous and new full versions match, exit 0 silently. The
#     bumper uses `git status` to detect the no-op case and skips the PR.
#
# Unlike bump-webhook.sh, remotedialer-proxy is also a real Go import in
# rancher/rancher (pkg/ext/rdp.go imports its forward/proxyclient packages),
# so this script additionally runs `go get` on the module itself — the
# chart-version bump into build.yaml alone does not touch go.mod, and the
# bumper's post-bundle `go mod tidy` pass is a no-op unless go.mod's
# require line was already changed by something in the bundle.
#
# Usage: bump-remotedialer-proxy.sh <new-version>
#   e.g. CHART_REF=dev-v2.15 bump-remotedialer-proxy.sh v0.8.0-rc.4
#
# Required tools in PATH: yq (v4), curl, go (for `go get`/`go generate`).
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <new-remotedialer-proxy-version>" >&2
    exit 2
fi
NEW_VERSION="$1"
CHART_REF="${CHART_REF:-}"

if ! echo "$NEW_VERSION" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'; then
    echo "Error: version $NEW_VERSION must be vX.Y.Z or vX.Y.Z-rc.N" >&2
    exit 1
fi
if [[ -z "$CHART_REF" ]]; then
    echo "Error: CHART_REF env var must be set to the rancher/charts branch (e.g. dev-v2.15)" >&2
    exit 1
fi

NEW_SHORT="${NEW_VERSION#v}"

# Resolve `<chart>+up<dep>` from rancher/charts' index.yaml. rancher/charts is
# public, so no auth is needed for raw.githubusercontent.com.
INDEX_URL="https://raw.githubusercontent.com/rancher/charts/${CHART_REF}/index.yaml"
NEW_FULL=$(curl -fsSL "$INDEX_URL" \
    | yq -r ".entries.\"remotedialer-proxy\"[] | select(.appVersion == \"${NEW_SHORT}\") | .version" \
    | head -n1)
if [[ -z "$NEW_FULL" ]]; then
    echo "Error: no remotedialer-proxy entry with appVersion=${NEW_SHORT} in ${INDEX_URL} — wait for the chart bump to merge first" >&2
    exit 1
fi

if [[ ! -f ./build.yaml ]]; then
    echo "Error: ./build.yaml not found — run from a rancher repo root" >&2
    exit 1
fi
if [[ ! -f ./go.mod ]]; then
    echo "Error: ./go.mod not found — run from a rancher repo root" >&2
    exit 1
fi

PREV_FULL=$(yq -r '.remoteDialerProxyVersion' ./build.yaml)
if [[ -z "$PREV_FULL" || "$PREV_FULL" == "null" ]]; then
    echo "Error: .remoteDialerProxyVersion missing from build.yaml" >&2
    cat ./build.yaml >&2
    exit 1
fi

GO_MODULE="github.com/rancher/remotedialer-proxy"
PREV_GO_VERSION=$(go list -m -f '{{.Version}}' "$GO_MODULE" 2>/dev/null || true)

if [[ "$PREV_FULL" == "$NEW_FULL" && "$PREV_GO_VERSION" == "$NEW_VERSION" ]]; then
    echo "bump-remotedialer-proxy: already at $NEW_FULL ($NEW_VERSION); nothing to do"
    exit 0
fi

yq --inplace ".remoteDialerProxyVersion = \"${NEW_FULL}\"" ./build.yaml

# go.mod's require line tracks the plain Go module version (e.g. v0.8.0),
# independent of the chart-prefixed build.yaml value above — bump it too so
# the two never drift apart the way they historically have.
GOFLAGS=-mod=mod go get "${GO_MODULE}@${NEW_VERSION}"
go mod tidy

go generate ./...

echo "bump-remotedialer-proxy: bumped build.yaml to ${NEW_FULL}, go.mod to ${NEW_VERSION}"
