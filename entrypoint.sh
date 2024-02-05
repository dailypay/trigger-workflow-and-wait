#!/usr/bin/env bash
set -e

usage_docs() {
  echo ""
  echo "You can use this Github Action with:"
  echo "- uses: convictional/trigger-workflow-and-wait"
  echo "  with:"
  echo "    owner: keithconvictional"
  echo "    repo: myrepo"
  echo "    github_token: \${{ secrets.GITHUB_PERSONAL_ACCESS_TOKEN }}"
  echo "    workflow_file_name: main.yaml"
}
GITHUB_API_URL="${API_URL:-https://api.github.com}"
GITHUB_SERVER_URL="${SERVER_URL:-https://github.com}"

validate_args() {
  wait_interval=10 # Waits for 10 seconds
  if [ "${INPUT_WAIT_INTERVAL}" ]
  then
    wait_interval=${INPUT_WAIT_INTERVAL}
  fi

  propagate_failure=true
  if [ -n "${INPUT_PROPAGATE_FAILURE}" ]
  then
    propagate_failure=${INPUT_PROPAGATE_FAILURE}
  fi

  trigger_workflow=true
  if [ -n "${INPUT_TRIGGER_WORKFLOW}" ]
  then
    trigger_workflow=${INPUT_TRIGGER_WORKFLOW}
  fi

  wait_workflow=true
  if [ -n "${INPUT_WAIT_WORKFLOW}" ]
  then
    wait_workflow=${INPUT_WAIT_WORKFLOW}
  fi

  if [ -z "${INPUT_OWNER}" ]
  then
    echo "Error: Owner is a required argument."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_REPO}" ]
  then
    echo "Error: Repo is a required argument."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_GITHUB_TOKEN}" ]
  then
    echo "Error: Github token is required. You can head over settings and"
    echo "under developer, you can create a personal access tokens. The"
    echo "token requires repo access."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_WORKFLOW_FILE_NAME}" ]
  then
    echo "Error: Workflow File Name is required"
    usage_docs
    exit 1
  fi

  client_payload=$(echo '{}' | jq -c)
  if [ "${INPUT_CLIENT_PAYLOAD}" ]
  then
    client_payload=$(echo "${INPUT_CLIENT_PAYLOAD}" | jq -c)
  fi

  ref="main"
  if [ "$INPUT_REF" ]
  then
    ref="${INPUT_REF}"
  fi
}

lets_wait() {
  echo "Sleeping for ${wait_interval} seconds"
  sleep "$wait_interval"
}

api() {
  path=$1; shift
  if response=$(curl --fail-with-body -sSL \
      "${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/actions/$path" \
      -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" \
      -H 'Accept: application/vnd.github.v3+json' \
      -H 'Content-Type: application/json' \
      "$@")
  then
    echo "$response"
  else
    echo >&2 "api failed:"
    echo >&2 "path: $path"
    echo >&2 "response: $response"
    if [[ "$response" == *'"Server Error"'* ]]; then 
      echo "Server error - trying again"
    else
      exit 1
    fi
  fi
}

lets_wait() {
  local interval=${1:-$wait_interval}
  echo >&2 "Sleeping for $interval seconds"
  sleep "$interval"
}

# Return the ids of the most recent workflow runs, optionally filtered by user
get_workflow_runs() {
  since=${1:?}
  run_name=${2:?}

  query="event=workflow_dispatch&created=>=$since&per_page=100"

  echo "Getting workflow runs using query: ${query}, filtering by tags: ${run_name}" >&2

  api "workflows/${INPUT_WORKFLOW_FILE_NAME}/runs?${query}" |
  jq --arg run_name "$run_name" -r '.workflow_runs[] | select(.name | contains($run_name))) | .id' |
  sort
}

trigger_workflow() {
  START_TIME=$(date +%s)
  SINCE=$(date -u -Iseconds -d "@$((START_TIME - 120))") # Two minutes ago, to overcome clock skew

  OLD_RUNS=$(get_workflow_runs "$SINCE")

  echo >&2 "Triggering workflow:"
  echo >&2 "  workflows/${INPUT_WORKFLOW_FILE_NAME}/dispatches"
  echo >&2 "  {\"ref\":\"${ref}\",\"inputs\":${client_payload}}"

  api "workflows/${INPUT_WORKFLOW_FILE_NAME}/dispatches" \
    --data "{\"ref\":\"${ref}\",\"inputs\":${client_payload}}"

  NEW_RUNS=$OLD_RUNS
  while [ "$NEW_RUNS" = "$OLD_RUNS" ]
  do
    lets_wait
    NEW_RUNS=$(get_workflow_runs "$SINCE")
  done

  # Return new run ids
  join -v2 <(echo "$OLD_RUNS") <(echo "$NEW_RUNS")
}

comment_downstream_link() {
  if response=$(curl --fail-with-body -sSL -X POST \
      "${INPUT_COMMENT_DOWNSTREAM_URL}" \
      -H "Authorization: Bearer ${INPUT_COMMENT_GITHUB_TOKEN}" \
      -H 'Accept: application/vnd.github.v3+json' \
      -d "{\"body\": \"Running downstream job at $1\"}")
  then
    echo "$response"
  else
    echo >&2 "failed to comment to ${INPUT_COMMENT_DOWNSTREAM_URL}:"
  fi
}

wait_for_workflow_to_finish() {
  run_name=${1:?}

  echo "Waiting for workflow with tags ${run_name} to finish"

  START_TIME=$(date +%s)
  SINCE=$(date -u -Iseconds -d "@$((START_TIME - 120))") # To account for clock skew

  match_found=false
  while [ "$match_found" = false ]; do
    lets_wait
    RUN_IDS=$(get_workflow_runs "$SINCE" "$run_name")

    for run_id in $RUN_IDS; do
      if [ ! -z "$run_id" ]; then
        match_found=true
        workflow=$(api "runs/$run_id")
        conclusion=$(echo "${workflow}" | jq -r '.conclusion')
        status=$(echo "${workflow}" | jq -r '.status')

        echo "Checking run_id [${run_id}] conclusion [${conclusion}] status [${status}]"

        if [[ "${conclusion}" == "success" && "${status}" == "completed" ]]; then
          echo "Workflow completed successfully."
          break
        elif [[ "${status}" == "completed" ]]; then
          echo "Workflow finished with conclusion [${conclusion}]."
          break
        fi
      fi
    done
  done

  if [ "$match_found" = false ]; then
    echo "No matching workflow run found for tags ${run_name}"
    exit 1
  fi
}

main() {
  validate_args

  if [ "${trigger_workflow}" = true ]
  then
    run_ids=$(trigger_workflow)
  else
    echo "Skipping triggering the workflow."
  fi

  if [ "${wait_workflow}" = true ]
  then
    for run_id in $run_ids
    do
      wait_for_workflow_to_finish "$run_id"
    done
  else
    echo "Skipping waiting for workflow."
  fi
}

main
