#!/usr/bin/env bash
#
# 양자화 변형(INT8 / 6bit / 8bit palettized)을 받아 Metal 4 ML 패키지까지 만든다.
# coremltools가 필요 없다 — Apple이 변환해 둔 것을 받기만 한다.
#
# 사용:  ./Tools/fetch_variants.sh [INT8|P6|P8|all]
#
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main"
WANT="${1:-INT8}"

fetch_one() {
    local suffix="$1"
    local pkg="DepthAnythingV2SmallF16${suffix}.mlpackage"
    local out="DepthAnythingV2Small${suffix}.mtlpackage"

    if [ ! -d "Models/$pkg" ]; then
        echo "▸ $pkg 받는 중"
        mkdir -p "Models/$pkg/Data/com.apple.CoreML/weights"
        for f in "Manifest.json" "Data/com.apple.CoreML/model.mlmodel" "Data/com.apple.CoreML/weights/weight.bin"; do
            curl -fsSL "$REPO/$pkg/$f" -o "Models/$pkg/$f"
        done
    fi
    if [ ! -d "Models/$out" ]; then
        echo "▸ $out 변환 중"
        xcrun metal-package-builder -ml "Models/$pkg" -o "Models/$out"
    fi
    du -sh "Models/$pkg" "Models/$out"
}

case "$WANT" in
    all) fetch_one INT8; fetch_one P6; fetch_one P8 ;;
    *)   fetch_one "$WANT" ;;
esac

echo
echo "벤치:  xcrun swiftc -O -o /tmp/bench4 Tools/bench_mtl4ml.swift && /tmp/bench4 Models/DepthAnythingV2Small${WANT}.mtlpackage"
