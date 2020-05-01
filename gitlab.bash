#!/usr/bin/env bash

log() {
  echo "$(date "+%Y-%m-%d %H:%M:%S")" "$@" >&2
}

require_envs() {
  : "${GITLAB_BASE_URL:?}"
  : "${GITLAB_PRIVATE_TOKEN:?}"
  : "${GITLAB_PROJECT_ID:?}"
}

# https://docs.gitlab.com/ee/api/merge_requests.html#list-merge-requests
list_merge_requests() {
  require_envs
  local params=${1:-"state=opened&per_page=10000"}
  curl --silent --show-error --fail -X GET "$GITLAB_BASE_URL/api/v4/projects/$GITLAB_PROJECT_ID/merge_requests?$params" -H "PRIVATE-TOKEN: $GITLAB_PRIVATE_TOKEN"
}

# https://docs.gitlab.com/ee/api/notes.html#create-new-merge-request-note
comment_on_merge_request() {
  local verbose merge_request_iid comment
  while test "$#" -gt 0; do
    case "$1" in
      --verbose ) verbose="yes"; shift ;;
      --iid     ) merge_request_iid=$2; shift 2 ;;
      --comment ) comment=$2; shift 2 ;;
      *         ) break ;;
    esac
  done
  require_envs
  : "${merge_request_iid?}"
  : "${comment?}"
  : "${verbose:="no"}"

  if test "$verbose" = "yes"; then
    log "Comment on MR; merge_request_iid: $merge_request_iid, comment: $comment"
  fi
  curl --silent --show-error --fail -X POST \
    -H "PRIVATE-TOKEN: $GITLAB_PRIVATE_TOKEN" \
    -d "body=$comment" \
    "$GITLAB_BASE_URL/api/v4/projects/$GITLAB_PROJECT_ID/merge_requests/${merge_request_iid}/notes"
}

# https://docs.gitlab.com/ee/api/commits.html#post-the-build-status-to-a-commit
post_build_status() {
  local verbose sha state name target_url
  while test "$#" -gt 0; do
    case "$1" in
      --verbose    ) verbose="yes"; shift ;;
      --sha        ) sha=$2; shift 2 ;;
      --state      ) state=$2; shift 2 ;;
      --name       ) name=$2; shift 2 ;;
      --target-url ) target_url=$2; shift 2 ;;
      *            ) break ;;
    esac
  done

  require_envs
  : "${verbose:="no"}"
  : "${sha?}"
  : "${state?}"
  : "${name?}"
  : "${target_url?}"

  if ! (echo "$state" | grep -qE '^(pending|running|success|failed|canceled)$'); then
    echo "error: Invalid state" >&2
    return 1
  fi

  if test "$verbose" = "yes"; then
    log "Post build status; sha=$sha, state=$state, name=$name, target_url=$target_url"
  fi
  curl --silent --show-error --fail -X POST \
    -H "PRIVATE-TOKEN: $GITLAB_PRIVATE_TOKEN" \
    "$GITLAB_BASE_URL/api/v4/projects/$GITLAB_PROJECT_ID/statuses/${sha}" \
    -d "state=$state" \
    -d "name=$name" \
    -d "target_url=$target_url"
}

hook_merge_requests() {
  local verbose hook_id filter logdir cmd
  while test "$#" -gt 0; do
    case "$1" in
      --verbose ) verbose="yes"; shift ;;
      --hook-id ) hook_id=$2; shift 2 ;;
      --filter  ) filter=$2; shift 2 ;;
      --logdir  ) logdir=$2; shift 2 ;;
      --cmd     ) cmd=$2; shift 2 ;;
      *         ) break ;;
    esac
  done

  : "${verbose:="no"}"
  : "${hook_id?}"
  : "${filter?}"
  : "${cmd?}"
  : "${logdir?}"

  local full_filter
  full_filter=$(cat << FILTER
    map(select($filter))
      | map("\(.iid)\t\(.title)\t\(.labels)\t\(.source_branch)\t\(.target_branch)\t\(.sha)\t\(.web_url)")
      | .[]
FILTER
)

  local exit_status=0
  while IFS=$'\t' read -r iid title labels source_branch target_branch sha web_url; do
    if test "$verbose" = "yes"; then log "hooked \"$title\" $labels $source_branch -> $target_branch"; fi

    local commit_sha_short="${sha:0:7}"
    local log_file="$logdir/${hook_id}.${commit_sha_short}.log"

    if test -f "$log_file"; then
      if test "$verbose" = "yes"; then log "=> skip; log exists $log_file"; fi
      continue
    fi

    mkdir -p "$(dirname "$log_file")"
    if env MERGE_REQUEST_IID="$iid" \
      SOURCE_BRANCH="$source_branch" TARGET_BRANCH="$target_branch" \
      MERGE_REQUEST_URL="$web_url" \
      bash -ue -o pipefail -c "$cmd" &> "$log_file"; then
      if test "$verbose" = "yes"; then log "=> success; $log_file"; fi
    else
      if test "$verbose" = "yes"; then log "=> failed; $log_file"; fi
      exit_status=$?
    fi
  done < <(jq -r -c "$full_filter")
  return "$exit_status"
}

merge_request_json_for_jenkins() {
  : "${MERGE_REQUEST_IID?}"
  : "${SOURCE_BRANCH?}"
  : "${TARGET_BRANCH?}"
  : "${MERGE_REQUEST_URL?}"
  
  local template
  template=$(cat << 'EOS'
    {
      "parameter": [
        { "name": "MERGE_REQUEST_IID", "value": $merge_request_iid },
        { "name": "SOURCE_BRANCH",     "value": $source_branch },
        { "name": "TARGET_BRANCH",     "value": $target_branch },
        { "name": "MERGE_REQUEST_URL", "value": $merge_request_url }
      ]
    }
EOS
)
  
  jq -n -c \
    --arg merge_request_iid "$MERGE_REQUEST_IID" \
    --arg source_branch "$SOURCE_BRANCH" \
    --arg target_branch "$TARGET_BRANCH" \
    --arg merge_request_url "$MERGE_REQUEST_URL" \
    "$template"
}


if test "${BASH_SOURCE[0]}" = "$0"; then
  set -eu -o pipefail
  "$@"
fi
