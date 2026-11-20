#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
swiftc Sources/Buds/FastPair.swift Sources/Buds/Maestro.swift Tests/ProtocolChecks.swift -framework IOBluetooth -o .build/protocol-checks
.build/protocol-checks
