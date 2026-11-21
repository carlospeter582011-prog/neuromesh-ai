"""Check the Play upload size and packaging for the NeuroMesh Android bundle."""

import argparse
from pathlib import Path
import zipfile


MAX_AAB_BYTES = 200_000_000
ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")
FLUTTER_ASSETS = "base/assets/flutter_assets/"
DEBUG_METADATA = "BUNDLE-METADATA/com.android.tools.build.debugsymbols/"
EXCLUDED_FILES = {
    FLUTTER_ASSETS + "packages/piper_phonemize/assets/web/piper-phonemize-wasm-main.data",
    FLUTTER_ASSETS + "packages/sherpa_onnx_web/assets/sherpa-onnx-wasm-web.wasm",
}
STANDALONE_LIBRARIES = {
    'libproot.so', 'libproot_loader.so', 'libtalloc.so', 'libandroid-shmem.so',
}
REQUIRED_FILES = {
    f"base/lib/{abi}/{library}"
    for abi in ABIS
    for library in ("libapp.so", "libflutter.so")
} | {
    "base/lib/arm64-v8a/libllama_jni.so",
    "base/lib/arm64-v8a/libpiper_phonemize_core.so",
    "base/lib/arm64-v8a/libsherpa-onnx-c-api.so",
    FLUTTER_ASSETS + "packages/piper_phonemize/espeak-ng-data/phondata",
    FLUTTER_ASSETS + "packages/piper_phonemize/espeak-ng-data/phontab",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    args = parser.parse_args()

    errors = []
    size = args.bundle.stat().st_size
    print(f"Play AAB file: {size:,} bytes ({size / 1_000_000:.2f} MB)")
    if size >= MAX_AAB_BYTES:
        errors.append(f"Play AAB must be smaller than {MAX_AAB_BYTES:,} bytes")

    with zipfile.ZipFile(args.bundle) as bundle:
        files = {entry.filename for entry in bundle.infolist() if entry.file_size}
        if any(name.startswith(DEBUG_METADATA) for name in files):
            errors.append(f"Unexpected contents in {DEBUG_METADATA}")
        for name in sorted(EXCLUDED_FILES & files):
            errors.append(f"Unexpected web asset: {name}")
        for name in sorted(files):
            if name.startswith('base/lib/') and Path(name).name in STANDALONE_LIBRARIES:
                errors.append(f"Standalone Linux runtime in the Play bundle: {name}")
        for name in sorted(REQUIRED_FILES - files):
            errors.append(f"Missing required bundle entry: {name}")

    for error in errors:
        print(f"::error::{error}")
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
