# NeuroMesh AI development handoff

## Start here

NeuroMesh AI is a Flutter workspace for private local AI with optional cloud providers. Users can download or import models, chat with files, work with a tool-using agent, and connect compatible devices. Android uses Kotlin/JNI and bundled llama.cpp. The Windows and Linux packages include a CPU llama-server. See [GitHub](https://github.com/carlospeter582011-prog/neuromesh-ai) and [installation and build instructions](README.md).

Read this file, check the current branch and working tree, and review the latest GitHub runs and open pull requests before choosing work. Update this file when the next task, release status, or known limitations change.

## Release and verification

- **v1.0.139** was published from `b97a515d23a8d18ca2ad7dc0c2b3192038960398`. It includes tool discovery, Android shared-folder access, clickable replies, the narration fixes, and local Kitten and Kokoro synthesis. The Android 12 emulator passed installation and reinstallation. All six installers match the checksums on both release pages. The GitHub APKs use a temporary preview signer. [Release](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/v1.0.139) · [ARM64 APK](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/download/v1.0.139/NeuroMesh-AI-v1.0.139-arm64-dev.apk) · [Build and publication](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44796547105)
- **v1.0.135** was published from `1e92b4661314fcd7cee3c400afeac9cf82eec1c4`. The Android 12 emulator passed installation and reinstallation, and all six installers match the published checksums. The GitHub APKs use a temporary preview signer. [Release](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/v1.0.135) · [Build and publication](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44791100634)
- All 213 local Flutter tests passed with the real Artemis projector and two published voice models. Live Qwen 3.5 0.8B Artemis used tool discovery and executed the calculator. Physical Android calls, storage-provider operations, and two-device pairing remain to be verified. [Tool discovery](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/48) · [Offline voice](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/50)
- **v1.0.133** was published on 2026-11-20 from `1339ddf3e388b92131f3ec5fb778a45d37af8f2b`. All six installers match their published checksums, and Android 12 passed clean install and upgrade. Android is development-signed. [Release](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/v1.0.133) · [Build and publication](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44707175729)
- All 194 local Flutter tests passed. Live checks verified a renamed SmolVLM projector against the publisher’s file and checksum. Actual Android imports and pairing remain to be tested. [General matching](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/42) · [Composite projector follow-up](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/44)
- **v1.0.128** was published on 2026-11-20 from `a7b8630f0f25b69b6ad875df03c89726dbcb3730`. All six installers match their published checksums, and the Android 12 emulator passed clean install and upgrade. Android is development-signed. [Release](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/v1.0.128) · [Build and publication](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44652746758)
- All 188 Flutter tests passed locally. Live checks covered public web search and anonymous Pollinations generation. Linux host checks covered source-bound transfer connections, Artemis vision recovery and UTF-8 token decoding. Pairing and transfer on the originally reported physical Android devices remain open. [Model and connection fixes](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/38) · [Narration fix](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/40)
- **v1.0.113** was published on 2026-11-19 from `ebdfc84`. It contains two Android APKs, the Play AAB, a Windows x64 installer, and Linux x64 DEB and AppImage packages. Android is development-signed. [Release](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/v1.0.113)
- The release workflow passed analysis, tests, APK signature and architecture checks, Play bundle checks, Android emulator install and reinstall, desktop packaging and native image-runtime checks. The standalone APKs and AAB include the required Alpine launcher libraries. All six asset digests match the release checksum manifest on both release pages. [Workflow](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44532641823)
- All 164 Flutter tests passed locally, including search retries, HTML attachment follow-ups, small-context trimming, model-helper classification, cluster allocation, and Linux command confirmation. Physical ARM64 Alpine startup, voice playback, model-helper combinations, cluster performance, Windows command execution and SSH VM sessions still need device tests.
- Earlier tested releases were v1.0.100, v1.0.107, and v1.0.111. [Release history](https://github.com/carlospeter582011-prog/neuromesh-ai/releases)

## Where to work

| Area | Entry points and current behavior |
| --- | --- |
| Chat and agent | `lib/controllers/chat_controller.dart`, `lib/views/chat_view.dart`, `lib/services/agent_service.dart`. Chat supports text, attachments, cloud and local inference. Agent tools cover files, approved actions, MCP, and memory. |
| Projects, Skills and attachments | `lib/services/agent_service.dart`, `lib/services/skills_service.dart`, `lib/utils/skill_context.dart`, `lib/utils/page_text.dart`. Chats can use named workspaces. Explicit skill mentions are scoped to a chat. Local agent chat can retrieve additional context pages as needed. |
| Models and local inference | `lib/controllers/model_controller.dart`, `lib/services/hf_service.dart`, `lib/services/model_helper_service.dart`, `lib/services/inference_*.dart`. Some helper files are linked to a main model. Runtime and architecture compatibility depend on the model and platform. |
| Voice, images and devices | `lib/services/voice_service.dart`, `lib/services/voice_worker.dart`, `lib/services/pollinations_image_service.dart`, `lib/services/cluster_service.dart`, `lib/services/cluster_backup.dart`, `lib/services/openai_server_service.dart`. Platform capabilities vary. |
| Diagnostics | `lib/services/diagnostics_service.dart`, `lib/views/diagnostics_view.dart`, and `workers/diagnostics/`. The report UI previews the ZIP before sending. See [diagnostic delivery configuration](SECURITY.md#developer-diagnostic-delivery). |
| Packaging | `.github/workflows/android-release.yml`, `android/app/build.gradle.kts`, `scripts/package_linux.sh`, and `installer/neuromesh.iss`. Build jobs use Flutter 3.38.x. Android uses JDK 17 and application ID `com.neuromesh.ai`. |

## Run the checks

```bash
git submodule update --init --recursive
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
python -m unittest discover -s scripts -p 'test_report_build_config.py'
```

Full release packaging also needs the dependencies in the GitHub workflow. Linux packaging uses Ubuntu 24.04. The release uses version name `1.0.<run_number>` and Android version code `5000 + run_number`. The Play AAB uses `PLAY_BUILD=true`. Standalone APKs use `PLAY_BUILD=false` and can check for GitHub updates. Alpine downloads on supported ARM64 devices. GitHub APKs support a persistent signer. The preview pipeline uses a temporary key when signing credentials are unavailable. Follow [release signing](SECURITY.md#release-signing) and [Play Store preparation](docs/PLAY_STORE.md).

## Changes in v1.0.113

The device follow-up covers grounded web search and attachment replies, fitting smaller local contexts, model and helper imports, one-line model tabs, token-based Cloudflare Worker setup, and linked voice and text chats with cloned voice selection. The Android build now requires PRoot's shared-memory library in the AAB and both APKs. Open **Toolbox → AI tools → Alpine terminal** to use the terminal directly. ARM64 Alpine launch, audio playback, and model-helper compatibility still need device checks. [Device report](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/20)

**Settings → Setup → Downloads** recommends installing Alpine on builds that include its ARM64 runtime. Applying the selected settings starts the OS download. Developer packages and the agent’s command permission have their own controls. [Setup follow-up](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/22)

The Android cluster supports saved device weights plus speed, context and model-capacity profiles. The requested split applies on the next GGUF load and is bounded by available memory. Windows and Linux use the host shell by default. **Settings → Desktop command access** controls per-command, per-type, or all-command approval and can use a user-configured SSH VM. Multi-device inference and native Windows/SSH behavior still need device checks. [Cluster and desktop follow-up](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/24)

Hugging Face files, the active download list, the download queue, and My models show **Model**, **Helper**, or **Unknown**. The repository view keeps file sizes and compatibility notes. Model memory estimates stay in the local library and load checks. File details and the download confirmation offer a companion preview before you start a download. [Model files follow-up](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/26) · [Companion preview](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/29)

## Next tasks

1. On a real ARM64 phone, record the release version, device and Android version. Install and open the app, load a small GGUF, generate a reply, and exercise chat attachments and project workspace recovery. Record pass or fail and link a redacted report for failures.
2. Smoke-test the Windows installer and both Linux packages on target hosts. Record app launch, model loading and generation results. Verify signing and try the Play internal track before broader distribution.

## Android vision, cluster and device transfer follow-up

- **Artemis vision pair** — use the publisher’s `Qwen3.5-0.8B-Artemis-Q4_K_M.gguf` with `mmproj-BF16.gguf` or `mmproj-F16.gguf` from the same repository. The repository-based helper ID `mmproj-39d50a89a8cb459a6.gguf` corresponds to its BF16 projector. [Publisher files and compatibility notes](https://huggingface.co/turintech/Qwen3.5-0.8B-Artemis-GGUF)
- **GGUF load diagnosis** — Huihui’s `patch-all-5.gguf` contains 27 replacement tensors for compatible Unsloth base weights. NeuroMesh categorizes it as a helper before attempting to load. Complete 27B weights require substantially more memory than the reported tablet had available. [Publisher patch notes](https://huggingface.co/huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF#patch-unsloth-9)
- **Vision and calls** — Android bounds image encoding and reply length, serializes native context access and records the last image attempt for diagnostics. Use **Settings → Model parameters → Local model thinking** for supported GGUF templates. The call controls offer a camera switch on devices with both lenses.
- **Cluster** — Automatic and Best speed keep models local when memory allows. For larger models, they estimate layer placement using measured connection latency and advertised memory bandwidth. Voice and image-generation jobs already have separate assignments in **Workload placement**. GGUF projectors run on the inference device. Compare the same prompt, context and generation settings on one phone versus multiple phones before claiming a speedup.
- **Transfer** — **Settings → Device transfer** offers models, helpers, chats, portable preferences, saved memory, workspaces, documents, skills and voice profiles. Workspaces stream as authenticated records. Chats and other metadata still have per-category size limits. The receiving device can reinstall Alpine through Setup and open the restored workspace in its terminal. Re-enter credentials and re-pair devices on the destination.
- **Chat and diagnostics** — Automatic web search checks multiple providers. Literal audio-file requests use the WAV tool directly. Chat renders common inline and display LaTeX. The report screen shows sending progress and distinguishes Telegram rejection from network timeouts.
- **Device verification pending** — reproduce the Artemis photo prompt on physical ARM64, test a video call camera switch and two-device restore, and measure cluster throughput. Live Telegram delivery depends on the configured bot and target chat. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/31)

### Verification for the device follow-up

- All 168 Flutter tests passed locally, and GitHub passed analysis and tests on both follow-up PRs. [Application checks](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44568877126) · [Packaging workflow checks](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44570894587)
- Verified both downloaded Artemis file digests against the publisher. The bundled Android C++ wrapper ran on a Linux CPU against the repo’s llama.cpp with simulated JNI calls. It completed image, text, and image turns in order, returned a context error for an oversized image prompt, and answered another text turn after the error. Separately, llama-server b12543 at 4096 context completed two 576 × 768 synthetic image requests in about 4.6 seconds each with a 256-token image cap, compared with about 8.8 seconds each at its default image limit on the same host. This measures the host setup and simple image questions. [Publisher checksums](https://huggingface.co/turintech/Qwen3.5-0.8B-Artemis-GGUF/blob/main/README.md#verified-artifact-hashes)
- The v1.0.117 Android packaging attempt stopped while resolving Kotlin libraries. PR #33 added Maven Central to Flutter’s included Gradle plugin build. Run 44571481873 tracks the next Android and desktop packaging attempt. [Dependency fix](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/33) · [Release workflow](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44571481873)

## Optional model helpers, setup and LAN pairing

- For a GGUF with a vision projector, **My models → Load** offers **Load with vision helper** and **Load without helpers**. Text-only mode skips the projector download and load for that session. Loading the last model again and retrying a failed load retain the chosen mode. Importance-matrix files such as `imatrix_micro3.gguf` are classified as helpers.
- **Settings → Setup** recommends **Qwen 3.5 0.8B Artemis Q4_K_M** and the matching **BF16 projector**. The pair takes about 739 MB of storage. Supported Android builds preselect Alpine and its developer packages. The terminal shares the agent workspace. Command approvals retain the existing setting.
- Models and Chat show a down arrow near the bottom-right of long lists. It scrolls to the end of the current list or conversation.
- **Device transfer** and **Phone cluster** prefer local Wi-Fi or hotspot addresses and allow choosing among available interfaces. Android workers show Ready once the RPC socket is listening. Pairing can recheck a worker at a new discovered address. Transfer route errors omit the pairing token. Both devices need direct access to each other on the local network.
- All 173 Flutter tests passed locally. A Linux host smoke test verified the RPC readiness signal against a bound and an occupied port, and the transfer client reached an HTTP listener on the chosen private interface. Two physical Android devices still need a transfer and cluster pairing test. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/35)

## Imported projectors, online images and device transfer

- In **Models → My models**, the importer and loader reuse an installed GGUF vision helper when the main model and helper have the same specific family name, or when a known Artemis BF16 or F16 projector matches the publisher’s SHA-256. A saved manual link takes priority when its file is present. Ambiguous names can still be linked manually. **Load without helpers** continues to skip vision.
- Chat’s built-in `generate_image` tool prefers an active local or cluster image model. The fallback uses Pollinations’ public Sana endpoint and attributes online results in Chat. Explicit standalone image requests also work while no chat model is loaded. Confirm agent-composed online calls before sending the prompt. An anonymous 768 × 768 generation returned a valid Sana JPEG. Requests for other models were routed to Sana or hit the anonymous rate limit.
- **Models → Voice → Import voice models (.zip)** accepts multiple supported archives and reports per-file errors without stopping the batch.
- The transfer client first tries the system route, then up to two explicitly bound local IPv4 source addresses. It reuses the successful source for downloads and gives different recovery steps for no route, refused connections, and timeouts. Phone Cluster pairing tests alternate private addresses advertised by the worker before rediscovery. Test the receiver and sender on the original Android Wi-Fi setup and on a device hotspot. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/37)
- Local checks passed, including the real BF16 projector, a source-bound HTTP round trip, and direct chat image routing with no text model loaded. Physical Android transfer, vision and batch voice import still need device verification.

## Public web search and researched audio

- Search uses public DuckDuckGo and Wikipedia pages and public Bing and Google News feeds. It requires no credentials. The search query omits follow-up writing and audio instructions. Relevant results are ranked before the app reads supporting passages.
- An explicit request to search, write a paragraph and create an audio file runs those three stages in order. The WAV reads the sourced paragraph, with citation markers omitted. Repeated tool calls and unsuccessful context searches now lead to a single final answer pass.
- Android llama.cpp token streaming preserves UTF-8 characters across token boundaries and sends UTF-16 to Kotlin. A host check covered fragmented emoji, Arabic, malformed and ASCII characters. The app’s live web search returned sources for the reported sports question and the coding model question. Device reproduction remains open.

Normal writing requests that explicitly ask for narration use the same two-stage flow. Chat runs the writing stage with tools off, then sends the finished text to the WAV tool. No intermediate notes file is necessary. Local orchestration tests cover both writing requests from the user’s screenshot. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/39)

## Matching imported models and helpers

- **My models** classifies artifacts from their filenames and supported GGUF and Safetensors metadata. Renamed GGUF projectors and LoRA adapters can be identified from their headers. Associations use saved links, publisher base-model metadata, family names, and verified checksums from Hugging Face. The Artemis BF16 and F16 publisher digests are available offline.
- **Find main models** and **Find helpers** display compatible installed candidates and show the publisher’s repository when identified. A generic file with insufficient evidence can be searched by model name or repository, or linked manually after compatibility confirmation. Only supported GGUF vision projectors can be attached from this screen. Other helpers are identified and listed for comparison.
- Tests cover renamed projectors and adapters, general base-model associations, checksum matching, ambiguous files, and the genuine BF16 artifact. Physical Android import and pairing remain to be checked. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/41)
- A live SmolVLM projector check verifies the projector's published bytes and its finished model identity. Projector matching ignores training datasets and distinguishes the finished vision model from its language and vision components. [Composite projector follow-up](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/43)

## Online images, Android updates and navigation

- **Models → Images** explains the internet requirement and stores the optional Pollinations key in secure storage. Chat asks for missing details, can refine the prompt with the selected language model, and uses Pollinations for image creation. Keyless creation uses the anonymous Sana endpoint. A configured key enables selection from advertised free models. Edits require a source image, a key and a free editor that accepts images.
- Local image generation downloads and loading are retired. Vision helpers for understanding images remain a separate model capability.
- Android Back follows screen and tab history and asks before exiting the Home screen. The Models arrow jumps up and Back resets the Models list to the top. The Chat arrow jumps to the latest turn.
- Chat and voice call answers use the same selectable Markdown and math renderer. Named links, bare web addresses, and expanded source chips open in the browser. Voice playback and researched WAVs omit sources, URLs and citation numbers. If call playback stalls or produces silence, the app tries the system voice and keeps the response in the transcript. The call shows Speaking during audio playback and Preparing voice during synthesis.
- Android validates APK package, signer and version ahead of installation. GitHub APKs enable the updater. A persistent update signer can be configured through Actions settings. This GitHub integration cannot write repository secrets. Previously generated ephemeral signing keys cannot be recovered from the APK. [Signing setup](SECURITY.md#persistent-github-apk-updates)
- Android cluster workers can be restarted on another port. Pairing distinguishes refused connections, missing routes and timeouts. Two physical devices on the affected network still need verification. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/45)


## Tool discovery, shared folders and audio follow-ups

- Tool-enabled model turns can call `search_tools` using a task or capability. It lists up to three matching available tools with their argument schemas and asks the model to use the result. Blocked tools and capabilities that are unavailable are omitted. The small-context prompt includes the command when it fits.
- **Chat → Tools & permissions → Share a folder…** grants Android folder access through the system picker. The agent can list and read files, create and edit text files, append text, create subfolders, rename files and delete individual files. Changes ask by default. Android checks the saved write grant and relative path. Editing rejects binary and incomplete reads. The app's project workspace has its own files and revision history.
- Requests like “Create audio file talk about the importance of sports” draft the narration and call the built-in WAV tool. A request to turn the previous answer into speech uses that answer as input, omits sources and links the new WAV. A tool-name correction can resume a pending narration request. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/47)
- All 211 local Flutter tests passed. A live CPU smoke test with the published Qwen 3.5 0.8B Artemis GGUF verified that the model called `search_tools`, then `calculator`, and returned 133 for 19 × 7. The shared-folder tests verified tool approvals and Android channel arguments. The system picker and storage provider operations still need a physical Android test.

## Offline voice phonemes

- Sherpa-ONNX 2.x expects phoneme codepoints for English Kitten and Kokoro models. NeuroMesh initializes the bundled Piper phonemizer and supplies these codepoints to the model. Selected speakers keep their IDs. Kokoro multilingual input containing Chinese uses the available model lexicon.
- Host regression tests called the actual `text_to_speech` tool with the published Kitten Nano and Kokoro English archives. Both created WAVs with audible sample levels and plausible playback duration. To rerun, put the extracted voice folders under `NEUROMESH_TEST_VOICE_MODELS` and make the sherpa and Piper Linux native libraries available via `LD_LIBRARY_PATH`. Run `flutter test test/voice_model_synthesis_test.dart`. Android voice calls still need a device check. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/49)

## Opening images

- Generated image thumbnails, workspace image links, and call images open in the full-screen image viewer. The viewer supports zoom, download, and a separate Share button. File-backed images keep their original file type when saved or shared.
- Settings → Image generation shows the Pollinations panel. The page uses the panel's own state instead of an outer GetX observer that expected an observable value. Widget tests cover opening this page and tapping a generated image. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/51)
