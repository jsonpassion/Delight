#!/usr/bin/env bash
#
# 깊이 모델을 받아 Core ML / Metal 4 ML 양쪽 경로에서 쓸 수 있게 준비한다.
# 멱등하다 — 이미 있으면 건너뛴다.
#
set -euo pipefail

cd "$(dirname "$0")/.."
MODELS="Models"
REPO="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main"
PKG="DepthAnythingV2SmallF16.mlpackage"

echo "▸ 모델 받는 중 (약 49MB) — apple/coreml-depth-anything-v2-small, Apache-2.0"

if [ -d "$MODELS/$PKG" ]; then
    echo "  이미 있음, 건너뜀"
else
    mkdir -p "$MODELS/$PKG/Data/com.apple.CoreML/weights"
    for f in \
        "$PKG/Manifest.json" \
        "$PKG/Data/com.apple.CoreML/model.mlmodel" \
        "$PKG/Data/com.apple.CoreML/weights/weight.bin"
    do
        echo "  $f"
        curl -fsSL "$REPO/$f" -o "$MODELS/$f"
    done
fi

echo "▸ Core ML 컴파일 (.mlmodelc)"
if [ -d "$MODELS/DepthAnythingV2SmallF16.mlmodelc" ]; then
    echo "  이미 있음, 건너뜀"
else
    xcrun coremlcompiler compile "$MODELS/$PKG" "$MODELS/"
fi

echo "▸ Metal 4 ML 패키지 변환 (.mtlpackage)"
if [ -d "$MODELS/DepthAnythingV2Small.mtlpackage" ]; then
    echo "  이미 있음, 건너뜀"
else
    xcrun metal-package-builder -ml "$MODELS/$PKG" -o "$MODELS/DepthAnythingV2Small.mtlpackage"
fi

echo
echo "완료. 벤치로 확인:"
echo "  xcrun swiftc -O -o /tmp/bench4 Tools/bench_mtl4ml.swift && /tmp/bench4 Models/DepthAnythingV2Small.mtlpackage"
