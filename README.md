# Motorola Moto Z2 Play recovery build

Este repositorio compila o kernel `albus`, gera o DT correspondente e os
insere no TWRP oficial. O resultado usa nomes padrao e e publicado somente
como artifact do GitHub Actions.

## Escolhas fixadas

- Kernel: `SaaSD3v/android_kernel_motorola_msm8996`, commit
  `efe282d45dd09ce5ebc52a8f738a68a73cd3b4aa`.
- Defconfig: `albus_defconfig`.
- Unica mudanca temporaria de configuracao: `CONFIG_KSU=n`.
- Compiladores: GCC 4.9 ARM64 e ARM32 do AOSP `android-8.1.0_r52`.
- Recovery base: `twrp-3.5.0_9-0-albus.img`.
- Saida principal: `recovery.img`.

O TWRP 3.5.0 foi escolhido porque a imagem funcional verificada usa
exatamente o ramdisk dessa versao com um kernel 3.18.71 e um DT Motorola v3.
O ramdisk do TWRP 3.6.2 faria a imagem ultrapassar o limite fisico da particao
recovery antes mesmo de incluir todos os recursos atuais do kernel.

## Build

Abra `Actions`, selecione `Build recovery` e execute `Run workflow`. Um push
para `main` tambem inicia a compilacao.

O artifact `recovery` contem:

- `recovery.img`
- `Image.gz`
- `dt.img`
- `kernel.config`
- `build-info.txt`
- `SHA256SUMS`

O workflow interrompe a compilacao se detectar KernelSU, alteracoes de
configuracao fora de `CONFIG_KSU`, DT incorreto, ramdisk modificado ou imagem
maior que `21073920` bytes.

## Teste no aparelho

Teste primeiro sem gravar permanentemente, quando suportado pelo bootloader:

```sh
fastboot boot recovery.img
```

Depois do boot, confira o kernel e a configuracao:

```sh
adb shell uname -a
adb shell 'zcat /proc/config.gz | grep CONFIG_KSU'
```

O segundo comando deve mostrar `# CONFIG_KSU is not set`. Tambem devem ser
testados touch, ADB, armazenamento interno, cartao SD, USB e descriptografia.
