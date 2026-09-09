# phpbb-crowdin

Shared Crowdin sync tooling for phpBB extensions maintained by phpBB Modders. Given an extension directory, it creates or updates the extension's Crowdin project (including phpBB's custom formal/casual honorific language variants), then uploads source strings to Crowdin or downloads completed translations back into the extension.

## Contents

- **`crowdin-init.sh`** — the sync script. Run with `-h`/`--help` for the full option list.
- **`crowdin.conf`** — shared configuration applied to every phpBB extension (source language, source-sync toggle, CLI template path).
- **`crowdin.yml.template`** — Crowdin CLI configuration template; `crowdin-init.sh` fills in the phpBB language directory mappings at runtime.

## Requirements

- `bash`, `curl`, `jq`
- [Crowdin CLI](https://developer.crowdin.com/cli-tool/) (only required for source upload / translation download)

## Usage

```bash
export CROWDIN_API_TOKEN=your-personal-access-token
./crowdin-init.sh /path/to/phpbb-extension
```

Add `-n`/`--dry-run` to preview project changes without applying them, or `--download`/`--download-dry-run` to pull completed translations back into the extension.

Add `-s`/`--seed-untranslated` to also upload this extension's own local translation for any language that is still at 0% translated on Crowdin (every one of its files, not just some) — this only ever adds a starting point for translators; it never touches a language once real work exists for it on Crowdin, however partial. Requires a local translation that actually differs from the English source; a language directory that's just an untouched copy of English is not seeded.

## Contributing

Contributions are welcome!

- **Bug reports**: [Open an issue](https://github.com/phpbbmodders/phpbb-crowdin/issues).
- **Everything else** (questions, feature requests, ideas, general discussion): open an issue as well — this repository does not currently use Discussions.
- Pull requests are welcome for bug fixes or discussed features.

## Acknowledgments

- Code review, bug fixes, and documentation assisted by [Claude](https://www.anthropic.com/claude).

## License

This project is licensed under the **GNU General Public License v2.0**.

See [LICENSE](LICENSE) for more information.
