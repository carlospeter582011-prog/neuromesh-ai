# NeuroMesh AI

**Connect Devices. Multiply Intelligence.**

NeuroMesh AI is a Flutter app for running language models on Android, Windows and Linux. It combines local GGUF inference, optional cloud providers, an OpenAI-compatible local server, and device clustering.

See [the development handoff](continue.md) for release status, verification results, and the next tasks.

## Features

- Local GGUF inference on Android (llama.cpp, CPU with optional GPU backends)
- Cloud providers (bring your own API key) alongside local models
- Device clustering over the local network (worker discovery, QR / manual pairing)
- Local OpenAI-compatible API server
- OpenCode desktop preview with a local model in the Linux system terminal ([setup and supported features](docs/OPENCODE.md))
- Android 2.0 work in progress adds a standalone ARM64 OpenCode preview with Chat and Terminal. [Setup and verification status](docs/OPENCODE.md#android-20-standalone-preview)
- Document text extraction, public web search, and clickable links in assistant replies and voice transcripts
- Online image generation and editing through Pollinations
- Hugging Face search and download for GGUF models and helpers, with a queue and Wi-Fi-only option
- Voice calls with on-device listening and speaking, optional voice cloning (English) and a worker phone
- Chat with your documents (offline keyword search), agent with memory and remote MCP tools
- Toolbox: roles, prompts, profiles, export/import, backup, compare, benchmark

## Install

Choose the APK for Android, the x64 setup executable for Windows, or the x64 DEB or AppImage for Linux. The AAB is for Google Play distribution. [Downloads](../../releases)

The normal APK and AAB include the small ARM64 native Linux launcher. Alpine itself is an optional download from **Install Alpine Linux** in Chat tools or the terminal; it is not bundled with the app. Standalone APKs can check for GitHub updates. The Play AAB disables the built-in updater. Other Android ABIs can use chat features; the Alpine launcher currently requires ARM64. Store distribution of downloadable runtime packages still requires policy review.

In **Models**, filter **Main models** or **Helpers**. Open a model and choose **Find model helpers** to inspect its original repository. Downloaded vision helpers can be linked to a matching installed model. Reload the main model after the helper download completes. File-role detection uses names, and each helper shows its runtime and compatibility requirements.
GitHub preview APKs may use a temporary signing key. Android requires a matching signing certificate for an in-place update. [Signing setup](SECURITY.md#persistent-github-apk-updates)

## Images, audio and shared files

Ask Chat to create an image with Pollinations. Internet access is required. Keyless image generation uses Sana. To edit an uploaded image, add a Pollinations key under **Models → Images**. The app looks for a free editor compatible with the input image.

Ask for a narration by topic or ask Chat to turn its previous answer into a WAV file. Sources stay visible in Chat and are omitted from spoken audio.

On Android, use **Chat → Tools & permissions → Share a folder…** to give the agent access to a selected folder. The agent can read, create, edit, append, rename and delete files under the selected folder. Mutations ask for approval by default. Review or change access under **Tools & permissions**. The agent can look up available capabilities with `search_tools`.

## Skills and context

Open **Settings → Skills** to create a skill or import `SKILL.md` / a ZIP containing one skill folder, including `references`, `scripts` and `assets`. The format follows [Agent Skills](https://agentskills.io/specification). Imports validate metadata, reject links and unsafe archive paths, and never run scripts automatically. Enable or disable each skill locally. Tap **@** in the chat composer to pick a skill or a current-workspace file, or type `@skill:code-review` / `@file:"docs/notes.md"`.

For local agent chat, relevant enabled skills are selected using BM25 keyword ranking over names and descriptions. Selected documents are divided into overlapping pages. `read_context`, `search_context` and `list_skill_files` load the next relevant resources; active pages are rebuilt in the system prompt on each tool turn, separately from history compaction. This is bounded retrieval, not a guarantee that a small model follows arbitrarily long instructions. The app preserves the current user request and reports a capacity error instead of silently cutting mandatory instructions. Cloud text chat receives selected excerpts; paged agent tools currently require local agent chat. Explicit skill mentions remain active within the current chat until the skill is disabled; new chats select independently. Skill tasks never become cross-chat user memories.

Agent activity appears as a compact row. Open it for a live tool list and tap a step for request/result details. These show actual tool activity, not hidden model reasoning.

## Build

GitHub Actions runs analysis and tests on pull requests and packages Android, Windows and Linux on pushes to `main` or manual runs. Releases use one checksum manifest for all installers. For a local Android build, use Flutter 3.38.x, JDK 17, the Android SDK and NDK.

```bash
git submodule update --init --recursive
flutter pub get
flutter build apk --release
```

Release signing: see [`SECURITY.md`](SECURITY.md#release-signing).

## License

MIT — see [`LICENSE`](LICENSE). Bundled third-party components and their licenses are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
