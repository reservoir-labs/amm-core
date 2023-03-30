#!/bin/bash
set -euxo pipefail

for f in test/e2e/*.sh; do
  bash "$f"
done
