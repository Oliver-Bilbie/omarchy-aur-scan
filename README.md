# AUR Scan

This [Omarchy](https://omarchy.org) plugin sets up a yay pre-install hook which uses [aur-scanner](https://github.com/KiefStudioMA/ks-aur-scanner) to scan AUR packages before they are installed. If issues are found, the scan results can be passed to an agent for further investigation.

This plugin aims to strike a balance between reasonable security practices and low user friction. It should not be treated as a guarantee that packages are safe, but it should be much safer than the default Omarchy configuration.

*Click the thumbnail below to watch a demo video.*

[![Demo Video](https://i.ytimg.com/vi/ZJW6H3zUgf8/hq720.jpg)](https://www.youtube.com/watch?v=ZJW6H3zUgf8)

## How it works

When the plugin is enabled, it will prompt you to install [aur-scanner](https://github.com/KiefStudioMA/ks-aur-scanner) if it is not already present. It will then configure a yay pre-install hook. It also adds an **AUR Scan** item under **Setup → Security** in the Omarchy menu which is used to configure the aur-scanner threshold.

Disabling the plugin removes the hook and menu entry. You will be prompted to remove aur-scanner but you are not required to do so.

The hook scans each package yay is about to install or update. Results are printed in the terminal. If findings meet your chosen severity threshold, you are asked whether to investigate them with your default Omarchy agent, then whether to continue the installation. If the scan cannot run for any reason the install is aborted to avoid silently bypassing the process.

Omarchy's default agent launcher runs with full permissions, which didn't seem to fit well with the philosophy of this plugin. The yay hook instead copies the package into its own workspace and starts the default agent inside a [bubblewrap](https://github.com/containers/bubblewrap) sandbox. The sandbox does **not** bind the host root: only `/usr`, TLS/DNS stubs, mise, a fake home, and the package copy are visible. Fake home gets login credentials plus non-secret prefs (theme/UI); session history, skills, and MCP config stay out. Process environment is cleared (selected provider API keys are re-injected so the model still works). Network stays up for the model API and web lookup; shell, skills, and MCP are denied. Nested instruction files and workspace symlinks are stripped from the package copy.

> [!CAUTION]
> While precautions have been taken to minimize risks, using AI to analyze packages is unavoidably going to carry some risk of prompt injection.

> [!NOTE]
> The Codex and Crush agents are not supported as it is not possible to disable their shell permissions at this time — this presents a vector for them to leak keys from the environment.

## Severity threshold

**Setup → Security → AUR Scan** sets the minimum severity to report. Findings below that level are omitted from the output and are installed automatically.

| Level | Meaning |
| --- | --- |
| Critical | Only critical findings |
| High | High and critical |
| Medium | Medium and above (default) |
| Low | Low and above |
| Info | Everything, including informational findings |

## Install

```
omarchy plugin add https://github.com/oliver-bilbie/omarchy-aur-scan.git
omarchy plugin enable obilbie.aur-scan
```
When enabled, confirm the prompt that requests permission to install aur-scanner, and the prompt that requests permission to set up a yay hook.

## Remove

```
omarchy plugin remove obilbie.aur-scan
```
When disabled, you will be asked whether or not you wish to remove aur-scanner from your system.
All plugin-related yay configuration will be removed regardless.

## Dependencies

- [aur-scanner](https://github.com/KiefStudioMA/ks-aur-scanner) — prompted on first enable
- `bubblewrap` (`bwrap`) — required to sandbox the investigation agent

## AI Disclosure

Some of the code for this plugin was produced using AI tools. The development process involved producing a prototype by hand, and then using OpenCode to harden it into production code. This has allowed me to handle far more edge cases than I would otherwise have had time to code by hand!

## License

MIT. See [LICENSE](LICENSE).
