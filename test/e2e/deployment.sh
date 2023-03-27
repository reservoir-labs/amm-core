#!/bin/bash
set -euxo pipefail

# Constants
export TEST_PRIVATE_KEY=0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356

# Anvil cannot already be running or this will cause issues
nohup anvil --gas-limit 9000000 &>/dev/null &
anvil_pid=$!

# Kill anvil on exit.
function cleanup {
  echo "cleaning up anvil if it exists"
  test -z $anvil_pid || kill $anvil_pid
}
trap cleanup EXIT

# Lets anvil startup properly.
sleep 1

./test/helpers/setup_create2.sh
forge script scripts/test_deploy_curves.s.sol --broadcast --skip-simulation --slow --rpc-url http://localhost:8545 --private-key $TEST_PRIVATE_KEY
