# Toplexy Builder

Builds kernel with VNL / KWS / KSUN variants for sky/parrot.

## Variants

- `VNL` — vanilla, no root solution
- `KWS` — KernelSU (no SUSFS)
- `KSUN` — KernelSU-Next + SUSFS (susfs4ksu)

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

## Output

AnyKernel3 flashable zip + build log on failure + Telegram notifications.