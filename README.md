# Latest NVIDIA `.run` installer

`nvidia-latest.run.sh` installs NVIDIA's current Linux x86_64 driver on a headless Ubuntu 22.04 or 24.04 server with Turing-or-newer NVIDIA GPUs. It uses the open kernel modules required by RTX 5090 / Blackwell. Validation on additional GPU families is still needed; this is not an HGX/NVSwitch/Fabric Manager setup.

Each explicit invocation reads NVIDIA's live `latest.txt`; the driver version is not hard-coded. This follows the release NVIDIA designates as latest at that endpoint, not an arbitrary highest-numbered directory or beta. The selected version is fixed for that installation's reboot/resume sequence. Running it again later checks the endpoint again. It does not perform unattended upgrades on ordinary boots.

## Run

This changes the driver and automatically reboots the server, up to twice if Nouveau must first be disabled. Run on an idle server:

```bash
curl -fL https://raw.githubusercontent.com/username37263/deployment-scripts/main/nvidia-latest.run.sh -o nvidia-latest.run.sh
sudo bash nvidia-latest.run.sh
```

The launch command returns after scheduling a systemd service. That means **scheduled**, not installed successfully. Follow progress after reconnecting:

```bash
sudo journalctl -fu nvidia-latest-run.service
sudo cat /var/lib/nvidia-latest-run/phase
nvidia-smi
```

`complete` means the post-reboot checks passed for all NVIDIA display/compute GPUs discovered at the start, with the selected driver version, open kernel module and DKMS registration for the running kernel. `failed` requires review; the service does not reboot repeatedly or silently retry a failed installation. Logs are in the journal and `/var/log/nvidia-installer.log`.

The installer downloads the official `.run` file over HTTPS, checks NVIDIA's accompanying SHA-256, checks archive integrity, installs build prerequisites and matching headers/compiler, registers the driver with DKMS, and resumes from local state after reboots. It refuses to replace a distribution-packaged NVIDIA driver automatically, refuses active compute jobs/display managers, and does not disable Secure Boot. Secure Boot installations need a separate trusted module-signing workflow.

To run an additional small CUDA computation on every visible GPU (without installing the CUDA toolkit):

```bash
curl -fL https://raw.githubusercontent.com/username37263/deployment-scripts/main/verify-cuda.py -o verify-cuda.py
python3 verify-cuda.py
```

This test launches a small kernel, copies its results back, and validates every result on each GPU. It is a smoke test, not a prolonged thermal, power, memory or performance qualification.

NVIDIA driver versions (for example, `595.99.02`) and CUDA toolkit versions (for example, `13.x`) are different. This installs the **driver**, not the CUDA toolkit. The CUDA version displayed by `nvidia-smi` describes the driver's supported CUDA level.

The older `nvidia-driver.sh` is a separate Ubuntu-package test installer retained for existing pinned cloud-init configurations. Use `nvidia-latest.run.sh` for the latest `.run` workflow. No tokens, SSH keys or site addresses belong in this public repository.

## Verified hardware run

Tested 2026-09-17 UTC on Ubuntu 22.04.5 LTS, kernel `6.8.0-138-lowlatency`, with **2 × GeForce RTX 5090**:

- Official runfile driver **595.99.02**, SHA-256 `e87477958bf763070549324bd5ad6c948eba6ed210e44005b3eff84940f6e1ec`.
- Both GPUs reported **32607 MiB** VRAM and the expected driver after reboot.
- Open kernel module license: `Dual MIT/GPL`; DKMS showed the driver installed for the running kernel.
- The timer resumed verification automatically after the post-install reboot and disabled itself on success. A cloud-init ordering cycle discovered during the initial test was corrected by using this timer instead of attaching the service to `multi-user.target`.
- The CUDA Driver API test executed a kernel and checked 256 output values successfully on **each GPU**.
- No NVIDIA Xid or GPU-fallen-off-bus messages were found in the post-reboot kernel journal.
- `nvidia-smi` reported CUDA **13.2** compatibility; the CUDA toolkit was not installed.

This confirms the listed driver/hardware combination. A newer driver chosen by a future run still needs its own post-install verification.
