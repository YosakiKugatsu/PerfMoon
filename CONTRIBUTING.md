# Contributing to PerfMoon

[Open an issue](https://github.com/YosakiKugatsu/PerfMoon/issues) if you find a bug or want to discuss a feature. For a bug, include the PerfMoon version or commit, your Apple chip model, macOS version, steps to reproduce, and what you expected. For missing readings, check **Settings → Data Sources** and include the status shown for the affected source. Remove personal information from screenshots and logs, including process and volume names and mount paths.

For a pull request, explain what changes for users and how you checked it. Run `swift test --package-path PerfMoonKit` for collector or scheduler changes and `scripts/build.sh` to verify the app builds. For a hardware-specific change, say which Mac and macOS version you tested and which readings you could verify.

PerfMoon is released under [GPL-3.0-only](LICENSE). Preserve the notices for any code or assets you adapt from another project and explain their source and license in the pull request.
