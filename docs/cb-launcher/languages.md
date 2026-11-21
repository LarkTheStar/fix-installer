# Languages

## The CB launcher

`src/launcher-ui/assets/js/core/i18n.js` (about 248 KB) holds one JavaScript object,
`const translations = { en: {...}, fr: {...}, es: {...}, ru: {...} }`, nested by
section (`cb`, `nav`, `settings`, `game`, ...). Strings use `{{placeholder}}`
substitution. `setLanguage()` falls back to English when a language is missing and
sets `document.documentElement.lang`.

| Code | Language |
| --- | --- |
| `en` | English |
| `fr` | French |
| `es` | Spanish |
| `ru` | Russian |

The setting's own text: "Choose the interface language used by the launcher. This
setting only affects the launcher UI, not the in-game language." The launcher writes
no language setting for any game; the only game config it writes is Plutonium's
`config.json` (paths and `token`).

## This installer

The installer's language system is different in kind: it installs real language packs
for MW4 (13 languages, downloaded and SHA-256 checked) and switches the `language=`
value in `sp26\steam_settings\configs.user.ini`, with a ledger that reference-counts
shared files. Nothing from CB's language system applies to it. The new Games page
keeps the installer's English interface; the older games choose their language
through their own settings or Steam's language option.
