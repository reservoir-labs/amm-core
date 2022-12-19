OPTIMIZED_KEY=0x99e9ae9828cdef7c93783e78875678b18c99dc02a370bf61abf26c21caa0e0c1
UNOPTIMIZED_KEY=$(cat scripts/unoptimized-stable-mint-burn-key)

if [ "$FOUNDRY_PROFILE" == "coverage" ]
then
    sed -i "s/$OPTIMIZED_KEY/$UNOPTIMIZED_KEY/g" src/libraries/Constants.sol
else
    sed -i "s/$UNOPTIMIZED_KEY/$OPTIMIZED_KEY/g" src/libraries/Constants.sol
fi
