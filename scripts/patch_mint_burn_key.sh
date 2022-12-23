OPTIMIZED_KEY=$(cat scripts/optimized-stable-mint-burn-key)
UNOPTIMIZED_KEY=$(cat scripts/unoptimized-stable-mint-burn-key)

if [ "$FOUNDRY_PROFILE" == "coverage" ]
then
    echo "Running with coverage profile, setting StableMintBurn key..."
    sed -i "s/$OPTIMIZED_KEY/$UNOPTIMIZED_KEY/g" src/libraries/Constants.sol
else
    echo "Running with default profile, re-setting StableMintBurn key..."
    sed -i "s/$UNOPTIMIZED_KEY/$OPTIMIZED_KEY/g" src/libraries/Constants.sol
fi
