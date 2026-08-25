# AUR Scan

This [Omarchy](https://omarchy.org) plugin sets up a yay pre-install hook which uses [aur-scanner](https://github.com/KiefStudioMA/ks-aur-scanner) to scan AUR packages before they are installed. If issues are found, the scan results can be passed to an agent for further investigation.

This plugin aims to strike a balance between reasonable security practices and low user friction. It should not be treated as a guarantee that packages are safe, but it should be much safer than the default Omarchy configuration.

*Click the thumbnail below to watch a demo video.*

[![Demo Video](https://i.ytimg.com/vi/ZJW6H3zUgf8/hq720.jpg)](https://www.youtube.com/watch?v=ZJW6H3zUgf8)

## How it works

When the plugin is enabled, it will prompt you to install [aur-scanner](https://github.com/KiefStudioMA/ks-aur-scanner) if it is not already present. It will then configure a yay pre-install hook.
The hook scans each package yay is about to install or update. Results are printed in the terminal. If findings meet your chosen severity threshold, you are asked whether to investigate them with your default Omarchy agent, then whether to continue the installation. If the scan cannot run for any reason the install is aborted to avoid silently bypassing this process.

Omarchy's default agent launcher runs with full permissions, which didn't seem to fit well with the philosophy of this plugin. The yay hook instead copies the package into its own workspace and starts the default agent inside a [bubblewrap](https://github.com/containers/bubblewrap) sandbox. The sandbox is built so that prompt injection cannot reach host secrets.

- Host credentials never enter the sandbox. A host-side broker reads API keys / OAuth tokens and attaches them to model requests. The agent only sees a one-time session token and `http://127.0.0.1:<port>`.
- The sandbox shares the host network so the agent can look up package docs. It cannot read host files or environment secrets.
- Environment is cleared. Fake home gets theme/UI files only — no `auth.json`, no session DBs, no skills, no MCP config.
- The host root is not bound. Visible filesystem is `/usr`, TLS/DNS stubs, the agent install, a package copy, and fake home. Instruction files and workspace symlinks are stripped from the copy.

## Agent authentication

The broker uses a **provider API key** on the host. It does **not** use Claude Pro/Max or ChatGPT Plus/Codex website logins.

| Works | Does not work |
| --- | --- |
| `ANTHROPIC_API_KEY` (`sk-ant-…` from [console.anthropic.com](https://console.anthropic.com)) | `claude login` / Claude Pro / Max |
| `OPENAI_API_KEY` (`sk-…` from [platform.openai.com](https://platform.openai.com)) | `codex login` / ChatGPT Plus |

Put the key in the environment or in OpenCode’s auth store. The sandbox never sees it.

> [!NOTE]
> Codex and Crush may run a shell inside the sandbox; they cannot see host secrets. GitHub Copilot cannot be pointed at the broker and so is not supported.

> [!WARNING]
> The sandbox should prevent malicious packages from leaking secrets or executing malicious code, however prompt injection may still make the model mis-report a package.

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
- `bubblewrap` (`bwrap`)
- `python3`

## AI Disclosure

Some of the code for this plugin was produced using AI tools. The development process involved producing a prototype by hand, and then using OpenCode to harden it into production code. This has allowed me to handle far more edge cases than I would otherwise have had time to code by hand!

## License

MIT. See [LICENSE](LICENSE).
