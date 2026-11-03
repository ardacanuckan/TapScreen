#!/bin/sh
# Cross-validated model experiments on recorded taps: scripts/experiment.sh [dataset.json] [all|sensors|lda|grids]
set -e
cd "$(dirname "$0")/.."
mkdir -p build/exp && cp tools/experiment.swift build/exp/main.swift
swiftc -O -swift-version 5 -framework IOKit Sources/Core/*.swift Sources/ML/*.swift Sources/Touch/Actions.swift build/exp/main.swift -o build/experiment
./build/experiment "$@"
