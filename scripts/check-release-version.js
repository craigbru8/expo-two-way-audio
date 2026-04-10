#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const packageJsonPath = path.join(__dirname, "..", "package.json");
const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
const releaseRef = process.argv[2] || process.env.GITHUB_REF_NAME || "";

if (!releaseRef) {
  console.error("Missing release ref. Pass a tag like v0.2.5 or set GITHUB_REF_NAME.");
  process.exit(1);
}

if (!/^v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(releaseRef)) {
  console.error(`Release ref "${releaseRef}" must be a tag in the form vX.Y.Z.`);
  process.exit(1);
}

const expectedVersion = releaseRef.slice(1);
if (packageJson.version !== expectedVersion) {
  console.error(
    `package.json version "${packageJson.version}" does not match tag "${releaseRef}".`,
  );
  process.exit(1);
}

console.log(`Release tag ${releaseRef} matches package.json version ${packageJson.version}.`);
