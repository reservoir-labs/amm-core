OPTIMIZED_KEY=0xffc5ad74baa9d5ad8a9547da8063aab8b925963d87a72ab4eac0ef7acc613055
UNOPTIMIZED_KEY=0xc5e1a30a68be844e410a5e805ec9cfa3aa3ab5e53c1ca0eaadf29099ef88e5c9

if [ "$FOUNDRY_PROFILE" == "coverage" ]
then
    sed -i "s/$OPTIMIZED_KEY/$UNOPTIMIZED_KEY/g" src/libraries/Constants.sol
else
    sed -i "s/$UNOPTIMIZED_KEY/$OPTIMIZED_KEY/g" src/libraries/Constants.sol
fi
