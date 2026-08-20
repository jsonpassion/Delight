#!/usr/bin/env python3
"""
Depth Anything V2 모델 양자화 · f16 인터페이스 변환 스크립트.

이 스크립트는 coremltools가 있는 환경(별도 venv)에서 실행한다:
    python3 -m venv /tmp/ct && /tmp/ct/bin/pip install coremltools
    /tmp/ct/bin/python Tools/quantize_model.py --mode int8
    /tmp/ct/bin/python Tools/quantize_model.py --mode palettize --bits 6
    /tmp/ct/bin/python Tools/quantize_model.py --mode fp16io

산출물은 Models/quantized/ 에 생긴다. 검증 후 다음으로 치환한다:
    xcrun metal-package-builder -ml Models/quantized/<이름>.mlpackage \
        -o Models/DepthAnythingV2Small.mtlpackage
    xcrun swiftc -O -o /tmp/bench4 Tools/bench_mtl4ml.swift && \
        /tmp/bench4 Models/DepthAnythingV2Small.mtlpackage

⚠️ 치환 후 반드시 확인할 것 (docs/02-model-and-quality.md §4):
  1. bench_mtl4ml의 출력 검증 — min/max가 같으면(상수) 실패다
  2. probe_p1의 Core ML 교차검증 — r ≥ 0.99 (양자화는 1.0이 아닐 수 있다)
  3. fp16io 모드였다면 Metal4MLDepthProvider의 elementBytes(4→2)와
     Preprocess.metal / Stabilize.metal의 버퍼 타입(float→half)도 함께 바꿔야 한다
"""
import argparse
import pathlib
import sys

SOURCE = pathlib.Path("Models/DepthAnythingV2SmallF16.mlpackage")
OUT_DIR = pathlib.Path("Models/quantized")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", choices=["int8", "palettize", "fp16io"], required=True)
    parser.add_argument("--bits", type=int, default=6, help="palettize 비트 수 (4/6/8)")
    parser.add_argument("--source", default=str(SOURCE))
    args = parser.parse_args()

    try:
        import coremltools as ct
        import coremltools.optimize.coreml as cto
    except ImportError:
        print("coremltools가 없다. venv를 만들어 설치할 것:")
        print("  python3 -m venv /tmp/ct && /tmp/ct/bin/pip install coremltools")
        return 1

    source = pathlib.Path(args.source)
    if not source.exists():
        print(f"원본이 없다: {source} — 먼저 ./Tools/fetch_models.sh")
        return 1

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    model = ct.models.MLModel(str(source))

    if args.mode == "int8":
        # 가중치를 8비트 선형 양자화. M5의 GPU Neural Accelerator는 int8 경로가 있어
        # 대역폭 절반 + 커널 가속을 함께 노린다.
        config = cto.OptimizationConfig(
            global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
        result = cto.linear_quantize_weights(model, config)
        out = OUT_DIR / "DepthAnythingV2Small-int8.mlpackage"

    elif args.mode == "palettize":
        # 가중치를 2^bits 개 팔레트로 클러스터링. 정확도 손실이 int8보다 완만하다.
        config = cto.OptimizationConfig(
            global_config=cto.OpPalettizerConfig(mode="kmeans", nbits=args.bits))
        result = cto.palettize_weights(model, config)
        out = OUT_DIR / f"DepthAnythingV2Small-p{args.bits}.mlpackage"

    else:  # fp16io
        # 입출력 인터페이스를 fp32 → fp16으로. 변환된 MPSGraph의 캐스트 연산이 사라지고
        # 전처리·안정화 버퍼 대역폭이 절반이 된다. 앱 쪽 수정이 함께 필요하다(위 주석).
        spec = model.get_spec()
        from coremltools.models.utils import convert_double_to_float_multiarray_type  # noqa
        ct.utils.convert_neural_network_spec_weights_to_fp16  # 존재 확인용
        for feature in list(spec.description.input) + list(spec.description.output):
            if feature.type.HasField("imageType"):
                continue  # 이미지 타입은 그대로
        result = ct.models.MLModel(spec, weights_dir=model.weights_dir)
        # 실제 io 타입 변경은 재변환 경로가 필요하다:
        result = ct.convert(
            model, convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16,
            inputs=[ct.TensorType(name=spec.description.input[0].name, dtype="fp16")],
            outputs=[ct.TensorType(name=spec.description.output[0].name, dtype="fp16")])
        out = OUT_DIR / "DepthAnythingV2Small-fp16io.mlpackage"

    result.save(str(out))
    print(f"저장: {out}")
    print("다음: xcrun metal-package-builder -ml", out,
          "-o Models/DepthAnythingV2Small.mtlpackage")
    return 0


if __name__ == "__main__":
    sys.exit(main())
