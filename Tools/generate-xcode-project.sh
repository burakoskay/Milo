#!/bin/bash
set -euo pipefail

REQUIRED_VERSION="2.46.0"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen $REQUIRED_VERSION is required. Install it with: brew install xcodegen" >&2
    exit 69
fi

INSTALLED_VERSION=$(xcodegen version | awk '{print $2}')
if [[ "$INSTALLED_VERSION" != "$REQUIRED_VERSION" ]]; then
    echo "xcodegen $REQUIRED_VERSION is required; found $INSTALLED_VERSION." >&2
    exit 69
fi

xcodegen generate --no-env --spec project.yml --project .
