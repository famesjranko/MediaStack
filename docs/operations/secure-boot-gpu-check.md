# Secure Boot GPU check on GCP

Use this operator-run check to test the NVIDIA driver paths on a host with
Secure Boot on. It needs a GCP project with Tesla P4 quota. It keeps no VM or
image after the run. Each run creates its own key and image, then deletes
them.

## Why a custom image

A trusted signing key is necessary to load the NVIDIA kernel module under
Secure Boot. On real hardware, the user enrolls the DKMS key as a Machine
Owner Key (MOK) through MokManager at boot. That is not possible on GCP:
MokManager shows on the serial console, but the GCP firmware does not send
serial input to it. Linux on the same port accepts input.

Put the DKMS key in the firmware signature database (`db`) instead. GCP
accepts `db` entries when you create an image. Debian's kernel loads `db`
keys into the `.platform` keyring and accepts modules signed by them. Enrolled
MOK keys go into the `.machine` keyring. For module loading the two have the
same result. For key-state checks they are different:
`mokutil --test-key` reports a `db` key as `is already in db`, not
`is already enrolled`.

## Steps

Set the target. Pin the project on every command and do not change the active
gcloud configuration.

```bash
export CLOUDSDK_CORE_PROJECT=PROJECT_ID
ZONE=us-central1-a
BASE=ms-sb-base
IMAGE=ms-sb-dbkey
GPU_VM=ms-sb-gpu
LABEL=purpose=sb-gpu-check
```

### 1. Make a base disk with a DKMS key

Create a Shielded VM without a GPU. Generate the DKMS key in the path that
DKMS uses. Export the default firmware certificates, so that the image keeps
the Microsoft keys that shim needs.

```bash
gcloud compute instances create "$BASE" --zone "$ZONE" \
  --machine-type e2-standard-2 --image-family debian-12 --image-project debian-cloud \
  --boot-disk-size 60GB --boot-disk-type pd-standard \
  --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring --labels "$LABEL"

gcloud compute ssh "$BASE" --zone "$ZONE" --command '
  set -e
  sudo apt-get -qq update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -qq -y install mokutil efitools keyutils \
    dkms "linux-headers-$(uname -r)" build-essential pkg-config libglvnd-dev git ffmpeg
  sudo mkdir -p /var/lib/dkms
  sudo openssl req -new -x509 -nodes -days 36500 -subj "/CN=DKMS module signing key" \
    -newkey rsa:2048 -keyout /var/lib/dkms/mok.key -addext "extendedKeyUsage=codeSigning" \
    -outform DER -out /var/lib/dkms/mok.pub
  mkdir -p ~/keys && cd ~/keys
  for v in PK KEK db; do sudo efi-readvar -v $v -o $v.esl >/dev/null; sudo sig-list-to-certs $v.esl $v; done
  sudo cp /var/lib/dkms/mok.pub mok.der && sudo chown "$USER" ./*'

mkdir -p .tmp/sb-keys
gcloud compute scp --zone "$ZONE" "$BASE:~/keys/*.der" .tmp/sb-keys/
```

`.tmp/` is gitignored. The key files hold only public certificates. The
private key stays on the disk.

### 2. Make the image and delete the base VM

Use the exported file names. A stock Debian 12 image has one `PK`, two `KEK`
and four `db` certificates.

```bash
gcloud compute instances stop "$BASE" --zone "$ZONE"
cd .tmp/sb-keys
gcloud compute images create "$IMAGE" --source-disk "$BASE" --source-disk-zone "$ZONE" \
  --guest-os-features UEFI_COMPATIBLE,GVNIC --labels "$LABEL" \
  --platform-key-file PK-0.der --key-exchange-key-file KEK-0.der,KEK-1.der \
  --signature-database-file db-0.der,db-1.der,db-2.der,db-3.der,mok.der
cd -
gcloud compute instances delete "$BASE" --zone "$ZONE"
```

### 3. Start the GPU VM and confirm the setup

```bash
gcloud compute instances create "$GPU_VM" --zone "$ZONE" --machine-type n1-standard-4 \
  --accelerator type=nvidia-tesla-p4,count=1 --maintenance-policy TERMINATE \
  --image "$IMAGE" --boot-disk-size 60GB --boot-disk-type pd-standard \
  --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring --labels "$LABEL"

gcloud compute ssh "$GPU_VM" --zone "$ZONE" --command '
  mokutil --sb-state
  cat /sys/kernel/security/lockdown
  sudo keyctl show %:.platform | grep "DKMS module signing key"'
```

Continue only if Secure Boot is enabled, lockdown shows `[integrity]`, and the
DKMS key is in `.platform`. The GCP `debian-12` kernel has no nouveau module,
so no reboot is necessary before the driver install.

### 4. Run the cases

Get the driver that MediaStack would choose. Use the pinned nvidia-patch commit
from `scripts/lib/nvidia-patch.sh`. The P4 is Pascal, so use the 580 branch.

```bash
COMMIT=$(sed -n 's/^NVIDIA_PATCH_REPO_COMMIT="\(.*\)"/\1/p' scripts/lib/nvidia-patch.sh)
gcloud compute ssh "$GPU_VM" --zone "$ZONE" --command "
  ROW=\$(curl -fsSL https://raw.githubusercontent.com/keylase/nvidia-patch/$COMMIT/README.md \
    | grep -E '^\| *580\.' | grep '| YES |' | grep '\.run)' | tail -1)
  mkdir -p ~/nv && curl -fsSL -o ~/nv/drv.run \$(echo \"\$ROW\" | grep -oP 'https://[^)]+\.run')"
```

Run each case on the VM. The base flags are the ones in
`_nvidia_driver_install_run_file`.

```bash
FLAGS='--silent --dkms --no-x-check --no-cc-version-check --no-nouveau-check --no-install-compat32-libs'
SIGN='--module-signing-secret-key=/var/lib/dkms/mok.key --module-signing-public-key=/var/lib/dkms/mok.pub'
```

| Case | Command on the VM | Pass condition |
|---|---|---|
| A. Unlock flags today | `sudo sh ~/nv/drv.run $FLAGS --tmpdir ~/nv` | Records current behaviour |
| B. Unlock with signing | `sudo sh ~/nv/drv.run $FLAGS $SIGN --tmpdir ~/nv` | Exit 0; `modinfo -F signer nvidia` is `DKMS module signing key`; `nvidia-smi -L` lists the GPU |
| C. Kernel-upgrade rebuild | `sudo dkms remove nvidia/VER -k $(uname -r)`, then `sudo dkms install nvidia/VER -k $(uname -r)`, then reboot | DKMS prints `Signing module`; `nvidia-smi -L` works after the reboot |
| D. Unlock patch and NVENC | `bash patch.sh -c VER` and `sudo bash patch.sh -s` from a clone of nvidia-patch at `$COMMIT`, then an `h264_nvenc` encode with `ffmpeg` | Patch exits 0; the encode writes an H.264 stream |
| E. Key-state check | `mokutil --test-key /var/lib/dkms/mok.pub` | Records the text that `nvidia_driver_mok_state` must match |

`modinfo` is in `/usr/sbin`; call it by full path from a normal user.

### 5. Clean up

Delete the GPU VM and the image. Then confirm that nothing with the label
remains.

```bash
gcloud compute instances delete "$GPU_VM" --zone "$ZONE"
gcloud compute images delete "$IMAGE"
gcloud compute instances list --filter="labels.${LABEL%%=*}=${LABEL#*=}"
gcloud compute images list --no-standard-images --filter="labels.${LABEL%%=*}=${LABEL#*=}"
rm -rf .tmp/sb-keys
```

## Results

2026-10-31, Debian 12 (`6.1.0-54-cloud-amd64`), Tesla P4, driver 580.142,
dkms 3.0.10, nvidia-patch at the pinned commit.

| Case | Result |
|---|---|
| Control: signed test module on a stock image | Rejected: `Key was rejected by service` |
| Control: unsigned test module on the `db` image | Rejected |
| A | Fails. The installer loads its own unsigned build before DKMS signs, gets `Key was rejected by service`, and rolls back |
| B | Passes. Module signed by the DKMS key; `nvidia-smi -L` lists the P4 |
| C | Passes. DKMS signs the rebuilt modules with `/var/lib/dkms/mok.key`; the driver loads after a reboot |
| D | Passes. Patch applied; six concurrent `h264_nvenc` sessions ran |
| E | `/var/lib/dkms/mok.pub is already in db`, exit 1. `nvidia_driver_mok_state` matches only `already enrolled`, so it reports `not_enrolled` here |
