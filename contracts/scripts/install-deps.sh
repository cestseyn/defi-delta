#!/bin/sh
# Fetches pinned dependency releases into lib/. Tarballs are smaller and more reliable than recursive clones.
set -eu
cd "$(dirname "$0")/.."
mkdir -p lib

fetch() { # name repo tag
  name=$1; repo=$2; tag=$3
  if [ -f "lib/$name/.version" ] && [ "$(cat "lib/$name/.version")" = "$tag" ]; then return; fi
  rm -rf "lib/$name" && mkdir -p "lib/$name"
  curl -fsSL --retry 5 --retry-delay 2 "https://codeload.github.com/$repo/tar.gz/refs/tags/$tag" \
    | tar -xz -C "lib/$name" --strip-components 1
  echo "$tag" > "lib/$name/.version"
  echo "installed $name $tag"
}

fetch openzeppelin-contracts OpenZeppelin/openzeppelin-contracts v5.3.0
fetch openzeppelin-contracts-upgradeable OpenZeppelin/openzeppelin-contracts-upgradeable v5.3.0
fetch forge-std foundry-rs/forge-std v1.9.7
