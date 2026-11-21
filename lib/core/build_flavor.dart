/// True for the Play AAB, which disables the self-updater, restricted Android
/// permissions, and the optional standalone Linux and OpenCode runtimes.
const bool kPlayBuild = bool.fromEnvironment('PLAY_BUILD');

/// Legacy channel marker retained for compatibility with earlier builds.
const bool kProBuild = bool.fromEnvironment('PRO_BUILD');
