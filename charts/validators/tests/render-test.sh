#!/usr/bin/env bash
# Render tests for the validators chart: helm template + yq assertions, no cluster needed.
# Usage: charts/validators/tests/render-test.sh   (needs helm and mikefarah yq v4)
set -euo pipefail

CHART="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/base.yaml" <<'EOF'
type: lighthouse
suggestedFeeRecipient: "0x872C7af18F0de7A805C787bc149f3aD6f60499B3"
beaconChainRpcEndpoints: ["http://bn:5052"]
EOF

fails=0
check() { # check <description> <file> <yq expression that must print "true">
  if [ "$(yq "$3" "$2")" = "true" ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
sts() { helm template v "$CHART" -f "$TMP/base.yaml" "$@" | yq 'select(.kind == "StatefulSet")'; }
init='.spec.template.spec.initContainers[]'

# Default: init containers run as root, prepare chowns /data (unchanged behaviour).
sts > "$TMP/default.yaml"
check "default: get-configs runAsUser 0" "$TMP/default.yaml" \
  "$init | select(.name == \"get-configs\") | .securityContext | ((.runAsUser == 0) and ((keys | length) == 1))"
check "default: prepare runAsUser 0" "$TMP/default.yaml" \
  "$init | select(.name == \"prepare\") | .securityContext | ((.runAsUser == 0) and ((keys | length) == 1))"
check "default: prepare chowns /data" "$TMP/default.yaml" \
  "$init | select(.name == \"prepare\") | .command[2] | test(\"chown -R 1001:1001 /data\")"
check "default: no /tmp volume" "$TMP/default.yaml" \
  "[.spec.template.spec.volumes[] | select(.name == \"get-configs-tmp\")] | length == 0"

# Opt-in: strict non-root securityContext on both, no chown, /tmp emptyDir for get-configs.
sts --set initContainersNonRoot.enabled=true > "$TMP/nonroot.yaml"
for c in get-configs prepare; do
  sc="$init | select(.name == \"$c\") | .securityContext"
  check "nonroot: $c runAsNonRoot uid/gid 1001" "$TMP/nonroot.yaml" \
    "$sc | ((.runAsNonRoot == true) and (.runAsUser == 1001) and (.runAsGroup == 1001))"
  check "nonroot: $c no privilege escalation, read-only rootfs" "$TMP/nonroot.yaml" \
    "$sc | ((.allowPrivilegeEscalation == false) and (.readOnlyRootFilesystem == true))"
  check "nonroot: $c drops ALL capabilities, seccomp RuntimeDefault" "$TMP/nonroot.yaml" \
    "$sc | ((.capabilities.drop | ((length == 1) and (.[0] == \"ALL\"))) and (.seccompProfile.type == \"RuntimeDefault\"))"
done
check "nonroot: prepare does not chown" "$TMP/nonroot.yaml" \
  "$init | select(.name == \"prepare\") | .command[2] | test(\"chown\") | not"
check "nonroot: prepare still lays out lighthouse files" "$TMP/nonroot.yaml" \
  "$init | select(.name == \"prepare\") | .command[2] | test(\"cp /data/validator_definitions.yml /data/lighthouse/validators/\")"
check "nonroot: get-configs mounts /tmp" "$TMP/nonroot.yaml" \
  "$init | select(.name == \"get-configs\") | .volumeMounts | any_c(.name == \"get-configs-tmp\" and .mountPath == \"/tmp\")"
check "nonroot: /tmp is an in-memory emptyDir" "$TMP/nonroot.yaml" \
  ".spec.template.spec.volumes[] | select(.name == \"get-configs-tmp\") | .emptyDir.medium == \"Memory\""

# Opt-in with a uid that differs from the validator's must fail the render.
if helm template v "$CHART" -f "$TMP/base.yaml" --set initContainersNonRoot.enabled=true \
  --set initContainersNonRoot.securityContext.runAsUser=2000 > /dev/null 2>&1; then
  echo "FAIL nonroot: mismatched runAsUser renders"; fails=$((fails + 1))
else
  echo "ok   nonroot: mismatched runAsUser fails the render"
fi

[ "$fails" -eq 0 ] && echo "all render tests passed" || { echo "$fails render test(s) failed"; exit 1; }
