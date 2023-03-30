#!/bin/bash
set -euxo pipefail

# Constants
TEST_PRIVATE_KEY=0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356
CREATE2_EOA=0x3fab184622dc19b6109349b94811493bf2a45362
CREATE2_DEPLOY_RAW=0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222

if [ $(cast nonce $CREATE2_EOA) -eq 0 ]
then
    cast send \
        --value $(cast --to-wei 1 ether) \
        0x3fAB184622Dc19b6109349B94811493BF2a45362 \
        --from $(cast wallet address $TEST_PRIVATE_KEY) \
        --private-key $TEST_PRIVATE_KEY
    cast rpc "eth_sendRawTransaction" $CREATE2_DEPLOY_RAW

    echo "Create2Deployer deployed"
else
    echo "Create2Deployer already exists"
fi
