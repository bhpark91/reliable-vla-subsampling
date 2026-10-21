#!/usr/bin/env bash
set +e

export VESSLCTL_ORG="Bohyun-Park"
export VESSLCTL_TEAM="Default"

BUNDLE="$1"
JOBS="$BUNDLE/jobs.tsv"
LATEST="$BUNDLE/watch-latest.txt"
FINAL="$BUNDLE/final-summary.txt"

while true; do

    ALL_DONE=1
    : > "$LATEST"

    while IFS=$'\t' read -r FAMILY SLUG NAME; do

        STATE="$(
          vesslctl job show "$SLUG" 2>/dev/null \
          | awk -F: '/^State:/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}'
        )"

        [ -n "$STATE" ] || STATE="unknown"

        printf '%s=%s\n' "$FAMILY" "$STATE" >> "$LATEST"

        case "$STATE" in
          succeeded|failed|terminated|cancelled|canceled)
            ;;
          *)
            ALL_DONE=0
            ;;
        esac

    done < "$JOBS"

    if [ "$ALL_DONE" -eq 1 ]; then
        break
    fi

    sleep 20
done

{
  echo "===== CHATGPT_SUMMARY ====="

  while IFS=$'\t' read -r FAMILY SLUG NAME; do

      STATE="$(
        vesslctl job show "$SLUG" 2>/dev/null \
        | awk -F: '/^State:/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}'
      )"

      RESULT="NO_SUMMARY"

      if [ -f "$BUNDLE/$FAMILY/summary.env" ]; then
          RESULT="$(
            grep '^ENGINEERING_SMOKE=' \
              "$BUNDLE/$FAMILY/summary.env" \
            | cut -d= -f2
          )"
      fi

      STAGE=""
      if [ -f "$BUNDLE/$FAMILY/summary.env" ]; then
          STAGE="$(
            grep '^FAIL_STAGE=' \
              "$BUNDLE/$FAMILY/summary.env" \
            | cut -d= -f2
          )"
      fi

      printf '%s job=%s state=%s smoke=%s' \
        "$FAMILY" "$SLUG" "${STATE:-unknown}" "$RESULT"

      if [ -n "$STAGE" ]; then
          printf ' stage=%s' "$STAGE"
      fi

      printf '\n'

  done < "$JOBS"

  echo "TASK_SUCCESS_USED=false"
  echo "DISCOVERY500_OUTCOME_USED=false"
  echo "QUAL24_OUTCOME_USED=false"
  echo "FULL_LOG_ROOT=$BUNDLE"
} > "$FINAL"
