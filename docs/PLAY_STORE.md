# Publishing to Google Play (checklist)

Everything here is free except the one-time Play developer registration fee.

1. **Release signing.** Create an upload keystore and add the four repo secrets described in SECURITY.md. The workflow then produces a properly signed APK and AAB instead of a dev-signed pre-release. Keep the keystore backed up: losing it means you cannot update the app.
2. **Upload the AAB** (`NeuroMesh-AI-*.aab` from the release) to a Play Console internal-testing track first.
3. **Privacy policy URL.** Host PRIVACY.md (for example via GitHub Pages or the raw repo page) and paste the URL.
4. **Data safety form.** Declare: no data collected by the developer; data stays on device; microphone used for features, processed on device; network used to download models. Answer according to the final build.
5. **Content rating and target audience.** Complete the questionnaire. The app is a general-purpose AI chat tool and can generate unfiltered model output, so state that clearly in the store listing.
6. **App access / permissions declarations.** Foreground service (data sync / media processing) and microphone need a short justification.
7. **Store listing.** Name, short description, full description, 512x512 icon, feature graphic, at least 2 phone screenshots.
8. **Target API level and 64-bit.** The build already targets a recent API and ships arm64.
9. **AdMob (optional).** Not included. If you add ads, update the privacy policy and the Data safety form, and consider whether ads fit a privacy-first app.

## Bundle size

The release workflow verifies that the signed AAB is smaller than 200,000,000 bytes and separately measures the ARM64 download after Play splits the bundle. The bundle retains ARM64, ARMv7 and x86-64. Android release packaging omits native debug metadata and two browser-only voice payloads. Native Android voice libraries and phoneme data remain part of the bundle. The workflow uses Flutter to configure the project and Gradle to package the AAB. It then checks the packaged Flutter ELF binaries directly because Flutter 3.38 expects symbol metadata in the upload file.

The Play bundle excludes the optional standalone PRoot launcher. Its runtime check also disables Alpine installation and Android OpenCode. The GitHub standalone APK can offer the Alpine and OpenCode downloads with user consent. Keeping these executables outside the Play upload is a distribution decision. [Android OpenCode preview](OPENCODE.md#android-20-standalone-preview) · [Google Play's executable-code policy](https://support.google.com/googleplay/android-developer/answer/9888379)

For a packaging check, run **Android release** from GitHub Actions with **Build and verify a development-signed Play AAB artifact** enabled. The workflow uploads the verified bundle to the run without publishing a GitHub Release or using the production signing key. A locally built bundle can be checked with `python scripts/check_play_bundle.py build/app/outputs/bundle/release/app-release.aab`.

Enable **Test Android and desktop packages with development signing and upload them to Actions** to build all current packages together. This preview also checks startup from the universal APK and from Play-style split APKs on the Android emulator. The APKs, AAB, and Android checksum manifest are separate workflow artifacts.
