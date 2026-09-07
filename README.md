# Toplexy Builder

Builds the Toplexy kernel with VNL / KWS / KSUN variants for sky/parrot (Android 12, GKI 5.10), then publishes public download links (gofile + GitHub Release).

## Variants

- `VNL` — vanilla, no root solution
- `KWS` — KernelSU (manual-su: off, no SUSFS)
- `KSUN` — KernelSU-Next + SUSFS (susfs4ksu)

## Workflow

1. `build` — matrix (variant × platform × toolchain): clones kernel + sm8450-modules + device repo, patches KernelSU/susfs, builds + merges modules, packages AnyKernel3 zip (gofile upload is always attempted, zip >49 MB skips Telegram document upload)
2. `release` — on success: creates a per-run GitHub Release with every zip as an asset, updates the release notes, and posts the professional release message to Telegram (per-variant GitHub Release / gofile / Actions links + SHA256)
3. `notify` — on failure only: Telegram failure summary

## Secrets (Settings → Secrets and variables → Actions)

- `GIT_TOKEN` — GitHub token, Contents:Read, for private kernel repo only
- `TELEGRAM_BOT_TOKEN` — BotFather token
- `TELEGRAM_CHAT_ID` — your chat id

## Inputs (defaults)

- `ksu_variant`: `KWS`
- `platform`: `sky/parrot` (gki = gki_defconfig only; sky/parrot = merged gki + sky + parrot)
- `clang_variant`: `CLANG-19`
- `kernel_repo/ref`: `TopexGuy/kernel_xiaomi_sky` `17`
- `modules_repo/ref`: `TopexGuy/kernel_xiaomi_sm8450-modules` `17`
- `device_repo/ref`: `TopexGuy/device_xiaomi_sky` `17` (prebuilt dtbs/dtbo.img)
- `susfs`: `simonpunk/susfs4ksu` `gki-android12-5.10`
- `anykernel`: `anonytry/AnyKernel3` `master`
- `ksu`: `KOWX712/KernelSU` `master`
- `ksun`: `pershoot/KernelSU-Next` `dev-susfs`

Repo inputs accept `owner/repo` or full URL.

## Download (public, no login) — every build

- **gofile** — zip is always uploaded to gofile, public link sent to Telegram
- **GitHub Release** — `release` job creates one release per run with all zips as assets
- **Telegram** — zip ≤49 MB is uploaded as a document, otherwise a notice with the gofile link

GitHub Actions artifacts are not available without a login (GitHub policy); build log is only kept on failure.