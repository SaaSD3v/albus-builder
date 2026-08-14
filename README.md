# Motorola Moto Z2 Play recovery build

Este repositorio compila o kernel `albus`, gera o DT correspondente e os
insere no TWRP oficial. O resultado usa nomes padrao e e publicado somente
como artifact do GitHub Actions.

## Escolhas fixadas

- Kernel: `SaaSD3v/android_kernel_motorola_msm8996`, commit
  `516086ce0637a9e820793695a4dd8e3ff43e055b`.
- Defconfig: `albus_defconfig`.
- Fonte fixada antes da PR do KernelSU, sem seus arquivos ou integracao.
- Suporte ao ramdisk do recovery habilitado com `CONFIG_RD_LZMA=y`.
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

O workflow interrompe a compilacao se detectar qualquer arquivo, integracao,
configuracao, objeto ou simbolo KernelSU; tambem rejeita alteracoes de
configuracao fora do suporte LZMA, DT incorreto, ramdisk modificado ou imagem
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

O segundo comando nao deve produzir nenhuma saida, pois essa fonte nao possui
sequer o simbolo `CONFIG_KSU`. Tambem devem ser testados touch, ADB,
armazenamento interno, cartao SD, USB e descriptografia.
