OPTIMIZED_KEY=0xffc5ad74baa9d5ad8a9547da8063aab8b925963d87a72ab4eac0ef7acc613055
UNOPTIMIZED_KEY=0xd371909236c52b73d4891b6429499835678f81760528352597f48185358381ae

if [ "$FOUNDRY_PROFILE" == "coverage" ]
then
    sed -i "s/$OPTIMIZED_KEY/$UNOPTIMIZED_KEY/g" src/libraries/Constants.sol
else
    sed -i "s/$UNOPTIMIZED_KEY/$OPTIMIZED_KEY/g" src/libraries/Constants.sol
fi
