# img-packager

Build a custom Linux kernel and package it into a bootable CentOS distro
image (raw + Azure VHD) using [mkosi](https://github.com/systemd/mkosi).

The repo ships two composite GitHub Actions and a script to run everything
locally:

| Path             | What it does                                                        |
| ---------------- | ------------------------------------------------------------------- |
| `kernel-build/`  | Builds a Linux kernel from source → `boot/` + `lib/modules/`        |
| `.` (root)       | Packages a pre-built kernel into a disk image → `image.raw`, `.vhd` |
| `build-image.sh` | Runs the full pipeline (kernel → image → boot verify) locally       |

## Use in GitHub Actions

Chain the two actions: build the kernel, then feed its `kernel_dir` into the
packager.

```yaml
- uses: actions/checkout@v4
  with:
    path: linux # your kernel source tree

- name: Build kernel
  id: kernel
  uses: dblnz/distro-img-packager/kernel-build@main
  with:
    kernel_src: ${{ github.workspace }}/linux
    kernel_config: ${{ github.workspace }}/linux/arch/x86/configs/mshv_defconfig
    kernel_config_extra: |
      CONFIG_XFS_FS=y
    custom_label: "mshv-debug"

- name: Build image
  id: build
  uses: dblnz/distro-img-packager@main
  with:
    kernel_dir: ${{ steps.kernel.outputs.kernel_dir }}

- run: qemu-img info "${{ steps.build.outputs.image_path }}"
```

> mkosi needs unprivileged user namespaces. On some runners you may first need:
> `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`

See [`.github/workflows/test.yaml`](.github/workflows/test.yaml) for a complete
build-and-boot-verify pipeline.

### `kernel-build` action

| Input                 | Required | Description                                                    |
| --------------------- | -------- | -------------------------------------------------------------- |
| `kernel_src`          | yes      | Path to the kernel source tree                                 |
| `kernel_base_config`  | no       | Full base `.config` (defaults to the bundled CentOS 10 config) |
| `kernel_config`       | no       | Config fragment merged on top of the base                      |
| `kernel_config_extra` | no       | Inline `CONFIG_*` options, one per line (merged last)          |
| `custom_label`        | no       | Label appended to the kernel version string                    |

Configs are layered: base → `kernel_config` → `kernel_config_extra`. The
resulting version is `<version>-<actor>[-<custom_label>]-<commit>`.

**Outputs:** `kernel_dir` (staging dir with `boot/` and `lib/modules/`),
`kernel_version`.

### Image packager action (root)

| Input         | Required | Description                                            |
| ------------- | -------- | ------------------------------------------------------ |
| `kernel_dir`  | yes      | Kernel install dir (typically `kernel-build`'s output) |
| `output_name` | no       | Base filename for the VHD (default `image`)            |

**Outputs:** `image_path` (fixed-format VHD), `image_raw_path` (raw disk image).

## Run locally

`build-image.sh` runs the same pipeline without GitHub Actions. It clones the
kernel source if missing, builds it, produces the image, and boot-verifies it
in QEMU.

```bash
./build-image.sh            # run all steps
./build-image.sh kernel     # individual steps: kernel | install | image | convert | verify
```

Override defaults via env vars, e.g.:

```bash
KERNEL_VERSION=7.0.4 CUSTOM_LABEL=debug OUTPUT_NAME=myimage ./build-image.sh
```

Run `./build-image.sh --help` for the full list of steps and variables.

## Image contents

The image is a bootable CentOS 10 disk (`systemd-boot`) provisioned for Azure:
`cloud-init`, `WALinuxAgent`, Hyper-V daemons, and NetworkManager. See
[`conf/mkosi.conf`](conf/mkosi.conf) for the package list and kernel cmdline.
