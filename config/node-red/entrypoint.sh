#!/bin/bash
# ==============================================================================
# Node-RED entrypoint
# ==============================================================================
# Installs the npm packages listed in NODE_RED_PACKAGES (comma-separated, e.g.
# @flowfuse/node-red-dashboard@1) into /data, the same place the editor's
# palette manager installs to, then starts Node-RED with the image's own
# entrypoint. They're installed again only when the list changes, so only that
# start needs network access. Removing a package from the list doesn't
# uninstall it: use Manage palette in the editor.
#
# A failed install (no network, a typo) is logged and Node-RED starts anyway:
# the pipeline doesn't depend on these packages.
# ==============================================================================
set -u

packages="${NODE_RED_PACKAGES:-}"
stamp=/data/.p4n4-packages

if [ -n "$packages" ] && [ "$(cat "$stamp" 2>/dev/null)" != "$packages" ]; then
    echo "p4n4 node-red: installing $packages"
    set -f
    # shellcheck disable=SC2086  # one argument per package
    if (cd /data && npm install --no-audit --no-update-notifier --no-fund --save \
        --save-prefix=~ --omit=dev --engine-strict ${packages//,/ }); then
        echo "$packages" >"$stamp"
    else
        echo "p4n4 node-red: installing $packages failed; starting without them (retried on the next start)" >&2
    fi
    set +f
fi

cd /usr/src/node-red || exit 1
exec ./entrypoint.sh "$@"
