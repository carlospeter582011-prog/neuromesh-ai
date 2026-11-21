# Third-party notices

This project bundles open-source components that keep their own licenses:

| Component | Location | License |
|---|---|---|
| llama.cpp / ggml | `local_plugins/llama_flutter_android/android/src/main/cpp/llama.cpp` | MIT (license file inside that folder) |
| llama_flutter_android plugin | `local_plugins/llama_flutter_android` | see `local_plugins/llama_flutter_android/LICENSE` |
| flutter_litert_lm plugin | `local_plugins/flutter_litert_lm` | see `local_plugins/flutter_litert_lm/LICENSE` |
| sd_flutter_android plugin | `local_plugins/sd_flutter_android` | see `local_plugins/sd_flutter_android/LICENSE` |
| stable-diffusion.cpp (git submodule) | `local_plugins/sd_flutter_android/android/src/main/cpp/stable-diffusion.cpp` | MIT (upstream repository) |
| Dart/Flutter packages | `pubspec.yaml` | per-package licenses (viewable in-app via the Flutter license page) |
| xterm and zmodem | standalone Android terminal | MIT, copyright xuty ([xterm license](https://pub.dev/packages/xterm/license), [zmodem license](https://pub.dev/packages/zmodem/license)); both notices are included in Flutter's license registry |

The root `LICENSE` file (MIT) must be kept with any copy of this code.
