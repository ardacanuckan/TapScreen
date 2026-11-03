#!/bin/sh
# Headless tests: detector, features, learners (synthetic taps). No sensors or permissions needed.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 -framework IOKit Sources/Core/*.swift Sources/ML/*.swift Sources/Touch/Actions.swift Tests/main.swift -o build/tests
./build/tests
