#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly BASE_BUILDER="${ROOT_DIR}/scripts/build.sh"
readonly GENERATED_BUILDER="${ROOT_DIR}/scripts/.build-recovery-console-4.9-droidspaces.generated.sh"
readonly RECOVERY_CONSOLE_COMMIT="0be3707df843664cbb69323c954c34c1d41ed7c3"
readonly KERNEL_REPO_49="https://github.com/marcost2/kernel_motorola_msm8593_4.9.git"
readonly KERNEL_COMMIT_49="a9572cf3d93be15565ba24c163e3333971927f70"
readonly KERNEL_TREE_49="343f9d8d670495b28fd8f949cd66e982fea4ff58"

cleanup() { rm -f "$GENERATED_BUILDER"; }
trap cleanup EXIT

[[ -f "$BASE_BUILDER" ]] || { echo "error: base builder not found: $BASE_BUILDER" >&2; exit 1; }
[[ -f "${ROOT_DIR}/scripts/integrate-recovery-console.sh" ]] || { echo "error: recovery-console integration helper is missing" >&2; exit 1; }
[[ -f "${ROOT_DIR}/patches/4.9/0001-cgroup-restore-prefixed-aliases-for-DroidSpaces-LXC.patch" ]] || { echo "error: DroidSpaces cgroup patch is missing" >&2; exit 1; }
[[ -f "${ROOT_DIR}/patches/4.9/0002-android-preserve-network-AID-capabilities.patch" ]] || { echo "error: Android network AID patch is missing" >&2; exit 1; }

python3 - "$BASE_BUILDER" "$GENERATED_BUILDER" "$RECOVERY_CONSOLE_COMMIT" "$KERNEL_REPO_49" "$KERNEL_COMMIT_49" "$KERNEL_TREE_49" <<'PY'
from pathlib import Path
import re, sys
source=Path(sys.argv[1]); out=Path(sys.argv[2]); console_commit=sys.argv[3]; kernel_repo=sys.argv[4]; kernel_commit=sys.argv[5]; kernel_tree=sys.argv[6]
text=source.read_text()
def replace_once(old,new,label):
    global text
    if text.count(old)!=1: raise SystemExit(f"{source}: expected exactly one {label}, found {text.count(old)}")
    text=text.replace(old,new,1)
def sub_once(pattern,replacement,label,flags=0):
    global text
    text,n=re.subn(pattern,replacement,text,count=1,flags=flags)
    if n!=1: raise SystemExit(f"{source}: expected exactly one {label}, found {n}")

sub_once(r'readonly KERNEL_REPO="[^"]+"',f'readonly KERNEL_REPO="{kernel_repo}"','KERNEL_REPO')
sub_once(r'readonly KERNEL_COMMIT="[0-9a-f]{40}"',f'readonly KERNEL_COMMIT="{kernel_commit}"','KERNEL_COMMIT')
replace_once('''  "$ARTIFACT_DIR/recovery.img" \\
  "$ARTIFACT_DIR/Image.gz" \\
''','''  "$ARTIFACT_DIR/recovery.img" \\
  "$ARTIFACT_DIR/recovery-console-aarch64" \\
  "$ARTIFACT_DIR/Image.gz" \\
''','artifact cleanup anchor')
clone_line='clone_commit "$KERNEL_REPO" "$KERNEL_COMMIT" "$KERNEL_DIR"'
replace_once(clone_line,clone_line+f'''
[[ "$(git -C "$KERNEL_DIR" rev-parse HEAD^{{tree}})" == "{kernel_tree}" ]] \\
  || die "unexpected pristine Albus 4.9 source tree"
git -C "$KERNEL_DIR" apply --check "${{ROOT_DIR}}/patches/4.9/0001-cgroup-restore-prefixed-aliases-for-DroidSpaces-LXC.patch"
git -C "$KERNEL_DIR" apply "${{ROOT_DIR}}/patches/4.9/0001-cgroup-restore-prefixed-aliases-for-DroidSpaces-LXC.patch"
git -C "$KERNEL_DIR" apply --check "${{ROOT_DIR}}/patches/4.9/0002-android-preserve-network-AID-capabilities.patch"
git -C "$KERNEL_DIR" apply "${{ROOT_DIR}}/patches/4.9/0002-android-preserve-network-AID-capabilities.patch"
grep -Fq 'DroidSpaces/LXC compatibility' "${{KERNEL_DIR}}/kernel/cgroup.c" || die "DroidSpaces cgroup compatibility patch was not applied"
grep -Fqx '#include <linux/android_aid.h>' "${{KERNEL_DIR}}/security/commoncap.c" || die "Android AID capability compatibility patch was not applied"
if grep -Fq '#ifdef CONFIG_ANDROID_PARANOID_NETWORK' "${{KERNEL_DIR}}/security/commoncap.c"; then die "security/commoncap.c still gates Android AID capabilities behind paranoid networking"; fi''','kernel clone anchor')

config_pattern=re.compile(r'"\$\{KERNEL_DIR\}/scripts/config" --file "\$KERNEL_CONFIG" --enable RD_LZMA\n'+r'make "\$\{MAKE_ARGS\[@\]\}" olddefconfig\n\n'+r'diff -u \\\n'+r'.*?\|\| die "an unexpected kernel configuration changed"\n',re.S)
config_block=r'''readonly -a DROIDSPACES_REQUIRED_CONFIG=(
  SYSVIPC
  POSIX_MQUEUE
  FHANDLE
  CGROUPS
  CGROUP_FREEZER
  CGROUP_PIDS
  CGROUP_DEVICE
  CPUSETS
  CGROUP_CPUACCT
  MEMCG
  MEMCG_SWAP
  BLK_CGROUP
  CGROUP_SCHED
  FAIR_GROUP_SCHED
  CGROUP_BPF
  CHECKPOINT_RESTORE
  NAMESPACES
  UTS_NS
  USER_NS
  PID_NS
  IPC_NS
  NET_NS
  IPV6
  CGROUP_NET_PRIO
  CGROUP_NET_CLASSID
  DEVTMPFS
  VETH
  MACVLAN
  NET_L3_MASTER_DEV
  IPVLAN
  VXLAN
  BRIDGE
  BRIDGE_NETFILTER
  NETFILTER
  NETFILTER_ADVANCED
  NF_CONNTRACK
  NF_NAT
  NETFILTER_XTABLES
  NETFILTER_XT_MATCH_CONNTRACK
  NETFILTER_XT_MATCH_ADDRTYPE
  NETFILTER_XT_MATCH_RECENT
  NETFILTER_XT_MATCH_TCPMSS
  NETFILTER_XT_TARGET_MASQUERADE
  NETFILTER_XT_TARGET_REJECT
  IP_SET
  IP_SET_HASH_IP
  IP_SET_HASH_NET
  NETFILTER_XT_SET
  IP_NF_IPTABLES
  IP_NF_FILTER
  IP_NF_NAT
  IP_NF_TARGET_MASQUERADE
  IP_NF_TARGET_REJECT
  IP_NF_MANGLE
  NF_TABLES
  NF_TABLES_INET
  NFT_CT
  NFT_COUNTER
  NFT_LOG
  NFT_LIMIT
  NFT_MASQ
  NFT_NAT
  NFT_REDIR
  NFT_COMPAT
  NET_SCHED
  NET_CLS_ACT
  NET_CLS_CGROUP
  NET_ACT_BPF
  BPF_JIT
  OVERLAY_FS
  UNIX98_PTYS
  DEVPTS_MULTIPLE_INSTANCES
  SECCOMP
  IKCONFIG
  IKCONFIG_PROC
)
readonly -a DROIDSPACES_OPTIONAL_CONFIG=(
  CFS_BANDWIDTH
  CGROUP_PERF
  NETFILTER_XT_TARGET_CHECKSUM
  VLAN_8021Q
)
"${KERNEL_DIR}/scripts/config" --file "$KERNEL_CONFIG" --enable RD_LZMA
for symbol in "${DROIDSPACES_REQUIRED_CONFIG[@]}"; do "${KERNEL_DIR}/scripts/config" --file "$KERNEL_CONFIG" --enable "$symbol"; done
for symbol in "${DROIDSPACES_OPTIONAL_CONFIG[@]}"; do "${KERNEL_DIR}/scripts/config" --file "$KERNEL_CONFIG" --enable "$symbol"; done
"${KERNEL_DIR}/scripts/config" --file "$KERNEL_CONFIG" --disable ANDROID_PARANOID_NETWORK
make "${MAKE_ARGS[@]}" olddefconfig
'''
text,n=config_pattern.subn(config_block,text,count=1)
if n!=1: raise SystemExit(f"{source}: failed to replace 3.18 config override block")
verify_pattern=re.compile(r'if grep -Eq \'\^\(# \)\?CONFIG_KSU\(\[_= \]\|\$\)\' "\$KERNEL_CONFIG"; then\n'+r'.*?require_config \'CONFIG_IKCONFIG_PROC=y\'\n',re.S)
verify_block=r'''require_config 'CONFIG_RD_LZMA=y'
require_config 'CONFIG_DECOMPRESS_LZMA=y'
require_config 'CONFIG_LOCALVERSION="-perf"'
require_config '# CONFIG_LOCALVERSION_AUTO is not set'
require_config 'CONFIG_ALBUS_DTB=y'
require_config '# CONFIG_ANDROID_PARANOID_NETWORK is not set'
for symbol in "${DROIDSPACES_REQUIRED_CONFIG[@]}"; do
  grep -Fqx "CONFIG_${symbol}=y" "$KERNEL_CONFIG" || die "required DroidSpaces Linux 4.9 config was not retained: CONFIG_${symbol}=y"
done
for symbol in "${DROIDSPACES_OPTIONAL_CONFIG[@]}"; do
  if ! grep -Fqx "CONFIG_${symbol}=y" "$KERNEL_CONFIG"; then printf 'warning: optional DroidSpaces config unavailable after olddefconfig: CONFIG_%s\n' "$symbol" >&2; fi
done
'''
text,n=verify_pattern.subn(verify_block,text,count=1)
if n!=1: raise SystemExit(f"{source}: failed to replace 3.18 config verification block")
replace_once('''  "${KERNEL_OUT}/arch/arm64/boot/"

[[ "$(dd if="$DT_IMAGE" bs=1 count=4 status=none)" == "QCDT" ]] \\
''','''  "${KERNEL_OUT}/arch/arm64/boot/dts/qcom/"

[[ "$(dd if="$DT_IMAGE" bs=1 count=4 status=none)" == "QCDT" ]] \\
''','dtbTool input directory')
text=text.replace('check_size "$EXPECTED_DT_SIZE" "$DT_IMAGE"\n','').replace('check_sha256 "$REFERENCE_DT_SHA256" "$DT_IMAGE"\n','')
replace_once('''cp "$KERNEL_IMAGE" "${REPACK_DIR}/kernel"
cp "$DT_IMAGE" "${REPACK_DIR}/extra"

note "Repack recovery.img with the new kernel and matching DT"
''','''cp "$KERNEL_IMAGE" "${REPACK_DIR}/kernel"
cp "$DT_IMAGE" "${REPACK_DIR}/extra"

note "Validate SELinux mode of the pinned TWRP base"
grep -aFq 'androidboot.selinux=permissive' "$BASE_IMAGE" || die "pinned TWRP base is not explicitly SELinux permissive"
note "Integrate recovery-console into the TWRP ramdisk"
readonly RECOVERY_CONSOLE_BINARY="${WORK_DIR}/recovery-console-aarch64"
bash "${ROOT_DIR}/scripts/integrate-recovery-console.sh" "${REPACK_DIR}/ramdisk.cpio" "$MAGISKBOOT" "$WORK_DIR" "$RECOVERY_CONSOLE_BINARY"
[[ -x "$RECOVERY_CONSOLE_BINARY" ]] || die "recovery-console binary was not produced"
RECOVERY_CONSOLE_SHA256="$(sha256_of "$RECOVERY_CONSOLE_BINARY")"; readonly RECOVERY_CONSOLE_SHA256
PATCHED_RAMDISK_SHA256="$(sha256_of "${REPACK_DIR}/ramdisk.cpio")"; readonly PATCHED_RAMDISK_SHA256
[[ "$PATCHED_RAMDISK_SHA256" != "$TWRP_RAMDISK_SHA256" ]] || die "recovery-console integration did not modify the ramdisk"
note "Repack recovery.img with Linux 4.9, matching DT, DroidSpaces and recovery-console"
''','kernel/DT repack anchor')
replace_once('''check_sha256 "$TWRP_RAMDISK_SHA256" "${VERIFY_DIR}/ramdisk.cpio"
''','''check_sha256 "$PATCHED_RAMDISK_SHA256" "${VERIFY_DIR}/ramdisk.cpio"
cmp -s "${REPACK_DIR}/ramdisk.cpio" "${VERIFY_DIR}/ramdisk.cpio" || die "the recovery-console ramdisk changed during final repack"
''','final ramdisk verification')
replace_once('''note "Prepare the standard build artifacts"
cp "$KERNEL_IMAGE" "${ARTIFACT_DIR}/Image.gz"
''','''note "Prepare the standard build artifacts"
cp "$RECOVERY_CONSOLE_BINARY" "${ARTIFACT_DIR}/recovery-console-aarch64"
cp "$KERNEL_IMAGE" "${ARTIFACT_DIR}/Image.gz"
''','artifact copy anchor')
replace_once("  printf 'ramdisk_lzma=enabled\\n'\n","  printf 'ramdisk_lzma=enabled\\n'\n"+f"  printf 'kernel_source_tree=%s\\n' '{kernel_tree}'\n"+"  printf 'kernel_version=4.9\\n'\n  printf 'droidspaces=enabled\\n'\n  printf 'droidspaces_cgroup_alias_patch=ravindu644\\n'\n  printf 'droidspaces_android_aid_compat=enabled\\n'\n  printf 'android_paranoid_network=disabled\\n'\n"+f"  printf 'recovery_console_commit=%s\\n' '{console_commit}'\n"+"  printf 'recovery_console_sha256=%s\\n' \"$RECOVERY_CONSOLE_SHA256\"\n  printf 'recovery_console_path=/system/bin/recovery-console\\n'\n  printf 'recovery_console_boot=init-service\\n'\n  printf 'recovery_console_selinux=base-cmdline-permissive\\n'\n  printf 'overclock=disabled\\n'\n",'build-info recovery-console anchor')
replace_once('''    recovery.img \\
    Image.gz \\
''','''    recovery.img \\
    recovery-console-aarch64 \\
    Image.gz \\
''','SHA256SUMS anchor')
out.write_text(text); out.chmod(0o755)
PY

printf 'Recovery Console + DroidSpaces Linux 4.9 branch build\n'
printf 'Base recipe: recovery-console-clean\n'
printf 'Kernel source: %s\n' "$KERNEL_REPO_49"
printf 'Kernel commit: %s\n' "$KERNEL_COMMIT_49"
printf 'Kernel tree: %s\n' "$KERNEL_TREE_49"
printf 'Recovery Console commit: %s\n' "$RECOVERY_CONSOLE_COMMIT"
printf 'DroidSpaces: enabled (4.9-native config + cgroup/AID compatibility)\n'
printf 'KernelSU: absent from the pristine 4.9 source\n'
printf 'Overclock: disabled / not used\n\n'
bash "$GENERATED_BUILDER"
