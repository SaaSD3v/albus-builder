# Albus Recovery Console + DroidSpaces Linux 4.9

Branch dedicada: `recovery-console-droidspaces-4.9`

Esta branch nasce diretamente de `recovery-console-clean` e mantém o mesmo TWRP 3.5.0_9-0, o mesmo Recovery Console e o mesmo mecanismo de unpack/repack. A diferença é somente o lado do kernel: a receita troca o Linux 3.18 pela árvore limpa Linux 4.9 do Albus e aplica o suporte DroidSpaces apropriado para 4.9.

## Base

| Item | Fonte / configuração |
|---|---|
| Base da branch | `recovery-console-clean` |
| Kernel | `marcost2/kernel_motorola_msm8593_4.9` |
| Kernel branch de origem | `lineage-18.1` |
| Kernel commit | `a9572cf3d93be15565ba24c163e3333971927f70` |
| Kernel tree | `343f9d8d670495b28fd8f949cd66e982fea4ff58` |
| Kernel | Linux 4.9 |
| KernelSU | ausente da árvore original |
| Overclock | desativado / não usado |
| Recovery base | `twrp-3.5.0_9-0-albus.img` |
| Recovery Console | `SaaSD3v/recovery-console@0be3707df843664cbb69323c954c34c1d41ed7c3` |
| Final image | `artifacts/recovery.img` |

## Suporte DroidSpaces

O source 4.9 é clonado no commit original acima e recebe somente dois patches de compatibilidade antes da compilação:

1. `cgroup: restore prefixed aliases for DroidSpaces/LXC`
   - autoria preservada: `ravindu644 <droidcasts@protonmail.com>`;
   - mantém o arquivo cgroup Android sem prefixo e cria também o alias `controller.file`, necessário para runtimes LXC/DroidSpaces em mounts `noprefix`.
2. `android: preserve network AID capabilities with paranoid net off`
   - mantém `AID_NET_RAW` e `AID_NET_ADMIN` funcionais mesmo com `CONFIG_ANDROID_PARANOID_NETWORK=n`, evitando regressão de Wi-Fi/network services do Android antigo.

As flags são aplicadas na `.config` de build por `scripts/config` e depois normalizadas por `olddefconfig`; o `albus_defconfig` upstream não é editado no repositório de origem.

Entre as opções exigidas estão namespaces, device/pids/memory cgroups, veth/macvlan/ipvlan/vxlan, bridge, netfilter/iptables/NAT, ipset, nftables, overlayfs, devpts, checkpoint/restore e BPF/cgroup networking. `CONFIG_ANDROID_PARANOID_NETWORK` é explicitamente desabilitado.

## DT correto do Linux 4.9

A build compila `Image.gz` e os DTBs do próprio kernel 4.9. Em seguida usa o `dtbTool_custom --force-v3 --motorola 1` para montar um `dt.img` QCDT v3 a partir de `arch/arm64/boot/dts/qcom/`.

O recovery final portanto contém:

```text
TWRP 3.5.0_9-0 original
├── ramdisk TWRP + Recovery Console
├── Image.gz Linux 4.9
└── dt.img Albus Linux 4.9 (Motorola QCDT v3)
```

Isso evita misturar o kernel 4.9 com o DT antigo do Linux 3.18.

## Recovery Console

A integração do Recovery Console continua sendo a mesma de `recovery-console-clean`:

- binário AArch64 estático;
- `/system/bin/recovery-console` dentro do ramdisk;
- serviço stock `recovery` desabilitado;
- `recovery-console` iniciado no boot;
- perfil do Albus/TWRP preservado;
- ramdisk LZMA preservado;
- base TWRP permissiva validada antes do repack.

## Build

```bash
bash scripts/build-recovery-console.sh
```

Ou execute o workflow **Build Albus Recovery Console + DroidSpaces 4.9**.

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

`build-info.txt` registra a árvore 4.9 exata, o estado do DroidSpaces, o Recovery Console, o SHA do DT/kernel e confirma `overclock=disabled`.

## O que não é herdado

Esta branch não usa a antiga branch experimental 4.9 como base e não carrega código de overclock, KernelSU ou alterações antigas do Linux 3.18. Os patches antigos são usados apenas como referência de comportamento/proveniência; o build parte da árvore upstream 4.9 original fixada acima.
