#!/usr/bin/env bash
# sudo -E is ignored by sudo-rs on current hosted runners.
# Forward only the Port build contract; never dump or forward the whole environment.
set -Eeuo pipefail
(( $# > 0 )) || { echo "Usage: port-root-env.sh command [args...]" >&2; exit 2; }
names=(
    PATH JAVA_HOME JAVA_HOME_17_X64
    GITHUB_ENV GITHUB_WORKSPACE GITHUB_REPOSITORY GITHUB_SERVER_URL
    GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_ACTIONS CI RUNNER_TEMP
    RCLONE_REMOTE_NAME RCLONE_UPLOAD_DIR
    DEADZONE_REQUEST_ID DEADZONE_CALLBACK_URL DEADZONE_EVENT_SECRET
    DEADZONE_PROJECT DEADZONE_CONTROLLED_BUILD DEADZONE_CENTRAL_CONFIG
    DEADZONE_PRESENTATION_OWNER DEADZONE_SOURCE_REPOSITORY
    DEADZONE_STOCK_ROM_URL DEADZONE_PORT_ROM_URL
    DEADZONE_BUILDER_NAME DEADZONE_BUILDER_ID DEADZONE_BUILDER_USERNAME
    DEADZONE_ENABLE_SECONDARY_MIRRORS DEADZONE_UPLOAD_MAX_ATTEMPTS
    DEADZONE_UPLOAD_BASE_DELAY_SECONDS
    MEZO_CONTACT_LINK UPDATES_GROUP_LINK CHAT_GROUP_LINK
)
env_args=()
for name in "${names[@]}"; do
    if [[ -v "$name" ]]; then
        env_args+=("$name=${!name}")
    fi
done
exec sudo env "${env_args[@]}" "$@"
