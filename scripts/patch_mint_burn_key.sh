OPTIMIZED_ADDRESS=$(cat scripts/optimized-stable-mint-burn-address)
UNOPTIMIZED_ADDRESS=$(cat scripts/unoptimized-stable-mint-burn-address)

if [ "$FOUNDRY_PROFILE" == "coverage" ]
then
    echo "Running with coverage profile, setting StableMintBurn key..."
    sed -i "s/$OPTIMIZED_ADDRESS/$UNOPTIMIZED_ADDRESS/g" src/libraries/Constants.sol
else
    echo "Running with default profile, re-setting StableMintBurn key..."
    sed -i "s/$UNOPTIMIZED_ADDRESS/$OPTIMIZED_ADDRESS/g" src/libraries/Constants.sol
fi
