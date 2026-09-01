para compilar um recovery (twrp) com suporte as flags do droidspaces para o moto z2 play

| Item              | fontes/info                                                |
|-------------------|------------------------------------------------------------|
| Kernel fonte      | https://github.com/SaaSD3v/android_kernel_motorola_msm8996 |
| Kernel branch     | lineage-15.1                                               |
| Kernel commit     | 9a7416218ae637c4120c417b31428bb0747fdfdf                   |
| Versao do Kernel  | 3.18.71                                                    |
| Compilador ARM64  | GCC 4.9 — AOSP android-8.1.0_r52                           |
| Recovery base     | twrp-3.5.0_9-0-albus.img                                   |
| Saida             | recovery.img                                               |
| droidspaces       | https://github.com/ravindu644/Droidspaces-OSS              |

O build usa a tree atual da lineage-15.1 com `CONFIG_ANDROID_PARANOID_NETWORK=n` e o fix de capabilities do Wi-Fi em `security/commoncap.c`.

A source lineage-15.1 possui KernelSU, mas os builds de recovery desativam `CONFIG_KSU` somente no `.config` temporario do TWRP. Assim o recovery permanece sem KernelSU sem voltar para uma tree antiga.

A variante Bare tambem desativa temporariamente a camada opcional de firewall/IP-set para manter o comportamento Bare.

Build local usando a mesma configuracao dos Actions:

```bash
python3 scripts/run-current-kernel-builder.py scripts/build.sh
python3 scripts/run-current-kernel-builder.py scripts/build-bare.sh --bare
python3 scripts/run-current-kernel-builder.py "pasta overclock/build_overclock.sh"
```

twrp original (base)
https://twrp.me/motorola/motorolamotoz2play.html
https://dl.twrp.me/albus/
