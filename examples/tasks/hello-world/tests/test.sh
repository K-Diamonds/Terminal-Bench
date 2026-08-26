#!/usr/bin/env bash
set -euo pipefail

mkdir -p /logs/verifier
echo 0 > /logs/verifier/reward.txt

if [[ -f /app/hello.txt ]] && [[ "$(cat /app/hello.txt)" == "Hello, world!" ]]; then
  echo 1 > /logs/verifier/reward.txt
else
  echo 0 > /logs/verifier/reward.txt
fi

exit 0
