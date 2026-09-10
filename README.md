# Albus Recovery + Recovery Console

Branch dedicada: `recovery-console-clean`

Esta branch mantém a receita normal do recovery que já funcionava no Moto Z2 Play (`albus`) e acrescenta somente o `recovery-console` ao ramdisk do TWRP. Nenhum patch de overclock é usado nesta branch.

## Base preservada

| Item | Fonte / configuração |
|---|---|
| Kernel | `SaaSD3v/android_kernel_motorola_msm8996` |
| Kernel tree | lineage-15.1 atual usada pelo wrapper |
| Kernel commit padrão | `9a7416218ae637c4120c417b31428bb0747fdfdf` |
| Kernel | 3.18.71 |
| ARM64 kernel toolchain | GCC 4.9 AOSP `android-8.1.0_r52` |
| Recovery base | `twrp-3.5.0_9-0-albus.img` |
| Recovery Console | `SaaSD3v/recovery-console` |
| Recovery Console commit | `0be3707df843664cbb69323c954c34c1d41ed7c3` |
| Recovery Console toolchain | AArch64 musl from Droidspaces compiler release, SHA-256 pinned |
| Final image | `artifacts/recovery.img` |

O kernel continua usando a mesma lógica do builder normal: `CONFIG_ANDROID_PARANOID_NETWORK=n`, fix de capabilities de Wi-Fi em `security/commoncap.c`, KernelSU desativado somente no `.config` temporário do recovery e todas as validações já existentes no builder normal.

## O que esta branch acrescenta

O `recovery-console` é tratado como componente de userspace do recovery, não como parte do kernel.

A build:

1. Executa a mesma receita de kernel/TWRP usada por `scripts/build.sh` através de `scripts/run-current-kernel-builder.py`.
2. Clona o `recovery-console` em um commit fixo.
3. Aplica um perfil específico para o Moto Z2 Play/TWRP durante a build, sem alterar o repositório original do console:
   - shell padrão: `/sbin/sh`;
   - backlight: `/sys/class/leds/lcd-backlight/brightness`;
   - rotação: `0`;
   - margens: `10 px`;
   - `COLOR_BGR=0`;
   - shadow buffer desativado para o painel AMOLED;
   - CRTC blank desativado.
4. Compila `recovery-console-aarch64` estaticamente com musl.
5. Descompacta o ramdisk do TWRP.
6. Localiza o serviço Android init chamado `recovery` e adiciona `disabled` conforme a documentação do Recovery Console.
7. Instala o binário em `/system/bin/recovery-console`.
8. Adiciona o serviço:

```rc
service recovery-console /system/bin/recovery-console
    user root
    group root
    oneshot
    disabled
    seclabel u:r:recovery:s0

on boot
    start recovery-console
```

9. Se o ramdisk possuir `sepolicy`, aplica com `magiskpolicy` as permissões recomendadas pela documentação para `recovery`, `adbd` e `su`.
10. Repacota o TWRP com o mesmo kernel/DT da receita normal e com o novo ramdisk.
11. Descompacta novamente o `recovery.img` final e valida que:
    - o kernel é o compilado;
    - o DT é o compilado;
    - o ramdisk modificado não mudou durante o repack;
    - `/system/bin/recovery-console` existe e é executável;
    - o serviço `recovery-console` existe;
    - o serviço stock `recovery` está desativado;
    - o tamanho final cabe na partição recovery do Albus.

## Organização

```text
scripts/
├── build.sh                         # receita normal preservada
├── run-current-kernel-builder.py   # aplica a tree atual do kernel
├── build-recovery-console.sh       # orquestra a variante desta branch
└── integrate-recovery-console.sh   # compila e injeta somente o console
```

A receita do Recovery Console é gerada temporariamente em tempo de build a partir de `build.sh`. Assim, a lógica de kernel/TWRP continua tendo uma única fonte e esta branch adiciona apenas a etapa de userspace necessária.

## Build

```bash
bash scripts/build-recovery-console.sh
```

Ou use o workflow **Build Albus recovery + Recovery Console** no GitHub Actions.

## Artefatos

```text
artifacts/
├── recovery.img
├── recovery-console-aarch64
├── Image.gz
├── dt.img
├── kernel.config
├── build-info.txt
└── SHA256SUMS
```

`build-info.txt` também registra o commit e o SHA-256 do Recovery Console e marca explicitamente `overclock=disabled`.

## Overclock

Esta branch não usa CPU OC, GPU OC, patch de clock, patch de KGSL, patch de cpufreq nem alteração de frequência em DTS/DTB. O objetivo dela é exclusivamente:

```text
TWRP original
    +
kernel normal com suporte necessário ao ambiente
    +
Recovery Console no ramdisk
    =
recovery.img
```
