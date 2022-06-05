import path from "node:path";
import fs from "node:fs";

// define sources and targets
const lPoolPath = {
    source: path.resolve("out/HybridPool.sol/HybridPool.json"),
    target: path.resolve("reference/sushi-trident/artifacts/contracts/pool/hybrid/HybridPool.sol/HybridPool.json"),
};
const lFactoryPath = {
    source: path.resolve("out/HybridPoolFactory.sol/HybridPoolFactory.json"),
    target: path.resolve("reference/sushi-trident/artifacts/contracts/pool/hybrid/HybridPoolFactory.sol/HybridPoolFactory.json"),
};

// note: we may want to not directly inject the HybridPool in the future.
//       rather, we could inject a thin wrapper contract that exposed a Trident
//       friendly ABI. this way we could test the inners maths & accounting
//       while having more freedom with the adjusting the ABI
const lSources = [lPoolPath, lFactoryPath];
for (const aSource of lSources) {
    const lSource = JSON.parse(fs.readFileSync(aSource.source).toString());
    const lTarget = JSON.parse(fs.readFileSync(aSource.target).toString());

    // inject, bytecode, deployCode, and ABI
    lTarget.bytecode         = lSource.bytecode.object;
    lTarget.deployedBytecode = lSource.deployedBytecode.object;
    lTarget.abi              = lSource.abi;

    // re-write the file with 2 spaces indentation
    fs.writeFileSync(aSource.target, JSON.stringify(lTarget, undefined, 2));
}
