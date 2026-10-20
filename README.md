# oci-arm-retry

Keeps retrying until Oracle Cloud has free capacity, then creates your **Always Free Arm VM** (`VM.Standard.A1.Flex`, Ubuntu aarch64) for you.

If you've seen `Out of host capacity for shape VM.Standard.A1.Flex`, this is for you. Free Arm capacity comes and goes, so instead of clicking **Create** all day, the script tries every couple of minutes until one gets through, then stops.

It is a single bash script with no dependencies other than the [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm).

> **Status:** written and tested on Windows 11 with Git Bash, OCI CLI 3.95, Python 3.14 and the `ap-mumbai-1` region. Authentication, ID lookups and the retry loop on "out of capacity" were verified. A successful launch had not been observed when this was written. The Linux and macOS steps use the same script but are **untested**, and so are the "start on boot" recipes. Issues and pull requests are welcome.

## Contents

1. [Read this first: the free limit changed](#read-this-first-the-free-limit-changed)
2. [How it works](#how-it-works)
3. [Quick start](#quick-start)
4. [Full guide](#full-guide): [prerequisites](#1-prerequisites) · [OCI CLI and login](#2-install-the-oci-cli-and-log-in) · [SSH key](#3-create-an-ssh-key-for-the-vm) · [network](#4-make-sure-you-have-a-public-subnet) · [every variable and where to get it](#5-fill-in-oci-armenv-every-variable-and-where-to-get-it) · [run](#6-run-it) · [keep it running](#7-keep-it-running-across-restarts) · [after it succeeds](#8-after-it-succeeds)
5. [Command cheat sheet](#command-cheat-sheet)
6. [Safety](#safety) · [Troubleshooting](#troubleshooting) · [Prior art](#prior-art) · [License](#license)

## Read this first: the free limit changed

Oracle's [Always Free resources page](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) currently lists the Arm allowance as **2 OCPUs and 12 GB of memory in total**, plus **200 GB of block storage** (boot and block volumes combined). Older guides say 4 OCPU / 24 GB, and that is no longer what the docs say. News coverage reports Oracle reducing it in 2026 and some over-limit instances being stopped.

Check the current numbers yourself before you run anything. This project's defaults match the docs as of October 2026.

**Free Trial accounts can create resources above the free limit using trial credits, and Oracle won't stop you.** After the trial those could be billed. That is why the script has its own guard (see [Safety](#safety)).

## How it works

1. Reads your settings from `oci-arm.env`.
2. Refuses to start if the size is above the free limit.
3. Before each attempt, checks whether an instance with your display name already exists and stops if so.
4. Calls `oci compute instance launch`. On "out of capacity" or a timeout it waits and tries again. On "too many requests" it waits longer. On any other error it prints the error and stops.
5. On success it prints the instance ID and exits.

## Quick start

Already have the OCI CLI logged in, an SSH key, and a public subnet? Then:

```bash
git clone https://github.com/Khanaliasad/oci-arm-retry && cd oci-arm-retry
cp oci-arm.env.example oci-arm.env      # fill in the values, see section 5
./grab-arm.sh
```

On Windows, run the same from **Git Bash**, or use `start-grab.ps1` to run it hidden in the background. Everything else is explained below.

---

## Full guide

### 1. Prerequisites

You need an Oracle Cloud account (a Free Trial or Always Free account is fine), and a computer that can stay on while the script retries. It can take hours or days to get capacity.

**Windows**
- Git for Windows (provides Git Bash, which runs the script): `winget install Git.Git`
- Python 3.12 or 3.13: `winget install Python.Python.3.12` (Python 3.14 works with the workaround below)
- OpenSSH client (built into Windows 10/11, gives you `ssh` and `ssh-keygen`)

**Linux (Debian/Ubuntu shown)**
```bash
sudo apt update && sudo apt install -y git python3-pip openssh-client
```

**macOS**
```bash
brew install git python
```

### 2. Install the OCI CLI and log in

**Install**

Windows (PowerShell) or any OS with Python:
```bash
pip install oci-cli
```

Linux or macOS, Oracle's own installer (see the [official install guide](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm)):
```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

Check it works (open a new terminal first so the PATH updates):
```bash
oci --version
```

> **Windows: `oci` not found?** pip puts it in a Scripts folder that isn't on PATH. Find it with `python -c "import sysconfig;print(sysconfig.get_path('scripts'))"` and add that folder to PATH. `start-grab.ps1` does this for you.
>
> **Python 3.14: `pip install oci-cli` fails building PyYAML?** The CLI pins an old PyYAML with no wheel for 3.14. Easiest fix: use Python 3.12 or 3.13. Alternatively: `pip download oci-cli --no-deps`, install that wheel with `pip install --no-deps <file>.whl`, then install its other requirements yourself with `PyYAML==6.0.3`.

**Log in (create an API key)**

The script talks to Oracle with an API key. Two ways to make one.

*Option A, guided:*
```bash
oci setup config
```
It asks for three values, then creates the key pair and `~/.oci/config`:

| Question | Where to get it |
|---|---|
| User OCID | Console: profile icon (top right) > **My profile** > **OCID** > **Copy**. Starts with `ocid1.user.oc1..` |
| Tenancy OCID | Console: profile icon > **Tenancy: your-name** > **OCID** > **Copy**. Starts with `ocid1.tenancy.oc1..` |
| Region | Shown in the console top bar. Use its identifier, e.g. `ap-mumbai-1` (see the [region list](https://docs.oracle.com/en-us/iaas/Content/General/Concepts/regions.htm)) |

Say **Y** when asked to generate a new API signing RSA key pair.

*Option B, manual (what I used):*
```bash
mkdir -p ~/.oci && chmod 700 ~/.oci
openssl genrsa -out ~/.oci/oci_api_key.pem 2048
chmod 600 ~/.oci/oci_api_key.pem
openssl rsa -pubout -in ~/.oci/oci_api_key.pem -out ~/.oci/oci_api_key_public.pem
openssl rsa -pubout -outform DER -in ~/.oci/oci_api_key.pem | openssl md5 -c    # prints the fingerprint
```
Then create `~/.oci/config` yourself:
```ini
[DEFAULT]
user=ocid1.user.oc1..YOUR_USER_OCID
fingerprint=aa:bb:cc:...   # the fingerprint printed above
key_file=~/.oci/oci_api_key.pem
tenancy=ocid1.tenancy.oc1..YOUR_TENANCY_OCID
region=ap-mumbai-1
```

**Upload the public key (both options)**

Console: profile icon > **My profile** > **Tokens and keys** (or **API keys**) > **Add API key** > **Paste a public key**, then paste the contents of `~/.oci/oci_api_key_public.pem` (including the BEGIN and END lines) and click **Add**. Oracle shows a fingerprint. It must match the one in your config.

Never share or commit the private key (`oci_api_key.pem`).

**Test it** (use your tenancy OCID):
```bash
oci iam availability-domain list --compartment-id YOUR_TENANCY_OCID --query 'data[].name'
```
You should see something like `["HWVg:AP-MUMBAI-1-AD-1"]`. A `401 NotAuthenticated` means a typo in an OCID or fingerprint, or that the key was added less than a couple of minutes ago. Wait a minute and retry.

### 3. Create an SSH key for the VM

This is the key you'll use to log in to the VM. It's separate from the API key.

Linux, macOS, Git Bash, or PowerShell:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/oci_a1
```
(In PowerShell you can use `$env:USERPROFILE\.ssh\oci_a1` as the path.) Press Enter for no passphrase, or set one. This makes `oci_a1` (private, keep it safe) and `oci_a1.pub` (public, goes in the config).

### 4. Make sure you have a public subnet

The VM needs a **public subnet** so it can get a public IP.

- **Already have one?** Skip ahead.
- **Make one:** Console > **Networking** > **Virtual cloud networks** > **Start VCN Wizard** > **Create VCN with Internet Connectivity**. This creates a VCN with a public subnet, an internet gateway and a security list that allows SSH.
- **Making a subnet by hand?** Choose **Regional**, **Public Subnet**, and give it an IPv4 CIDR block such as `10.0.0.0/24`. A public subnet also needs an internet gateway and a route rule to it.

### 5. Fill in `oci-arm.env` (every variable and where to get it)

```bash
cp oci-arm.env.example oci-arm.env
```

Then edit it. It's plain `KEY="value"` lines. Use the commands below, replacing `YOUR_TENANCY_OCID`.

| Variable | What it is | Where to get it |
|---|---|---|
| `COMPARTMENT_ID` | Where the VM is created. Use your tenancy OCID for the root compartment. | The `tenancy=` line in `~/.oci/config`, or console: profile icon > **Tenancy** > **OCID**. For another compartment: **Identity & Security** > **Compartments**. |
| `REGION` | Region identifier | The `region=` line in `~/.oci/config`. Must be your **home region** for Always Free. |
| `AVAILABILITY_DOMAIN` | Which data centre | `oci iam availability-domain list --compartment-id YOUR_TENANCY_OCID --query 'data[].name'`. Many regions have only one. If your region has several and one is out of capacity, try another. |
| `SUBNET_ID` | A public subnet | Command below, or console: **Networking** > **Virtual cloud networks** > your VCN > **Subnets** > the subnet > **OCID**. |
| `IMAGE_ID` | The OS image. Must be **aarch64** (Arm). | Command below. Image OCIDs are different in each region. |
| `SSH_PUBLIC_KEY_FILE` | Public key from step 3 | `$HOME/.ssh/oci_a1.pub` (works in Git Bash, Linux and macOS) |
| `DISPLAY_NAME` | Name of the VM. Also used for the duplicate check. | Anything you like, e.g. `arm-ubuntu-1` |
| `OCPUS`, `MEMORY_GB`, `BOOT_GB` | Size | Defaults `2` / `12` / `200` match the free limit. The script refuses anything above its built-in caps. |
| `RETRY_SECONDS` | Wait between attempts | Default `120`. Don't go much lower, or Oracle rate-limits you. |
| `COOLDOWN_SECONDS` | Wait after a rate limit | Default `600` |

**List your subnets** (use a public one: `privateOnly` is `False`):
```bash
oci network subnet list --compartment-id YOUR_TENANCY_OCID --all \
  --query 'data[].{name:"display-name",privateOnly:"prohibit-public-ip-on-vnic",id:id}' --output table
```

**List Arm Ubuntu images** (newest first; pick an `aarch64` one; the non-Minimal image has more tools preinstalled):
```bash
oci compute image list --compartment-id YOUR_TENANCY_OCID \
  --operating-system "Canonical Ubuntu" --shape VM.Standard.A1.Flex \
  --sort-by TIMECREATED --sort-order DESC --limit 8 \
  --query 'data[].{name:"display-name",id:id}' --output table
```

> **Windows PowerShell and line breaks:** the multi-line commands above use `\` for bash. In PowerShell, put each command on one line, or run them in Git Bash.

### 6. Run it

**Linux, macOS, WSL, or Git Bash (foreground):**
```bash
chmod +x grab-arm.sh
./grab-arm.sh
```

**Background, keeps running after you close the terminal (Linux/macOS/WSL/Git Bash):**
```bash
nohup ./grab-arm.sh > provision.log 2>&1 &
tail -f provision.log
```

**Windows, hidden background process** (PowerShell):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-grab.ps1
Get-Content .\provision.log -Tail 10 -Wait
```
`start-grab.ps1` won't start a second copy if one is already running.

Each line of the log is one attempt. `out of capacity, retrying` is normal. The script ends when it prints `SUCCESS`, or when it hits an error that retrying can't fix.

### 7. Keep it running across restarts

The loop stops when your computer restarts, sleeps, or you log out. Starting it again is safe: the script checks for an existing VM first. For something automatic (these recipes are untested):

**Linux, cron:**
```bash
crontab -e
# add:
@reboot cd /path/to/oci-arm-retry && ./grab-arm.sh >> provision.log 2>&1
```

**Windows, Task Scheduler** (starts the loop at logon):
```powershell
schtasks /Create /SC ONLOGON /TN "oci-arm-retry" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\oci-arm-retry\start-grab.ps1"
```

A cheap always-on machine, like a free AMD micro instance in the same Oracle account, is a good place to run it. If you do, keep in mind it also needs the OCI CLI and your API key.

### 8. After it succeeds

The log shows the instance ID. Remove the task from cron or Task Scheduler if you added one, then:

```bash
# public IP (also shown in the console under Compute > Instances)
oci compute instance list-vnics --instance-id INSTANCE_OCID --query 'data[0]."public-ip"' --raw-output

# log in (the user is "ubuntu" on Ubuntu images)
ssh -i ~/.ssh/oci_a1 ubuntu@PUBLIC_IP
```

Port 22 is open in a standard VCN. To serve a website, also allow ports 80 and 443 in the subnet's **Security List** (console: your VCN > **Security** > the security list > **Add Ingress Rules**) and in the VM's own firewall (Ubuntu images ship iptables rules that block them).

Finally, check **Billing > Cost Analysis** in the console to confirm you aren't being charged.

---

## Command cheat sheet

| Task | Linux / macOS / Git Bash | Windows PowerShell |
|---|---|---|
| Start (foreground) | `./grab-arm.sh` | `bash ./grab-arm.sh` (Git Bash) |
| Start (background) | `nohup ./grab-arm.sh > provision.log 2>&1 &` | `.\start-grab.ps1` |
| Watch the log | `tail -f provision.log` | `Get-Content .\provision.log -Tail 10 -Wait` |
| Is it running? | `pgrep -fa grab-arm.sh` | `Get-CimInstance Win32_Process -Filter "Name='bash.exe'" \| Where-Object CommandLine -like '*grab-arm.sh*'` |
| Stop it | `pkill -f grab-arm.sh` | `Get-CimInstance Win32_Process -Filter "Name='bash.exe'" \| Where-Object CommandLine -like '*grab-arm.sh*' \| ForEach-Object { Stop-Process -Id $_.ProcessId }` |
| List your instances | `oci compute instance list --compartment-id TENANCY_OCID --query 'data[].{n:"display-name",s:"lifecycle-state"}' --output table` | same |
| Test login | `oci iam availability-domain list --compartment-id TENANCY_OCID` | same |
| Use another config file | `./grab-arm.sh my-other.env` | `bash ./grab-arm.sh my-other.env` |

## Safety

- **Free-limit guard:** the script exits immediately if `OCPUS`, `MEMORY_GB` or `BOOT_GB` is above the limits defined at the top of `grab-arm.sh` (2 / 12 / 200). Edit those only if Oracle's docs change, or if you knowingly accept charges.
- **No duplicates:** it stops after one successful launch, and it checks for an existing instance with the same display name before every attempt. Renaming the VM and re-running would bypass the name check, so don't re-run after it succeeds.
- **No secrets in the repo:** your API private key stays in `~/.oci/`. OCIDs are identifiers, not credentials, but `oci-arm.env` is still git-ignored so you don't publish your tenancy by accident.
- `oci-arm.env` is loaded with `source`, so only use a config file you wrote yourself.

## Troubleshooting

| Message | What it means |
|---|---|
| `Out of host capacity` | Normal. The script keeps retrying. Capacity often frees up overnight. |
| `401 NotAuthenticated` | Typo in an OCID or fingerprint, or the API key was added less than a few minutes ago. Compare your `~/.oci/config` with the "Configuration file preview" Oracle shows when you add the key. |
| `NotAuthorizedOrNotFound` (404) | A wrong or other-region OCID (subnet, image or compartment), or missing permissions. |
| `TooManyRequests` / `429` | You're asking too often. Increase `RETRY_SECONDS`. |
| `LimitExceeded` | You've reached a limit, for example you already have an Arm instance. The script stops. |
| `connection ... timed out` | Treated as retryable. |
| `Shape ... is not compatible with image` | `IMAGE_ID` is not an aarch64 image. Re-run the image list command. |
| `Permission denied (publickey)` when logging in | Wrong key or user. Use `ssh -i ~/.ssh/oci_a1 ubuntu@IP`, and make sure `SSH_PUBLIC_KEY_FILE` pointed at the matching `.pub`. |
| `oci: command not found` | The CLI's folder isn't on PATH. See step 2. |

Only one Arm instance can be created per run. Run it again with a different `DISPLAY_NAME` for a second one, if the free limit allows.

## Prior art

Other projects solve the same problem, and are worth a look:

- [hitrov/oci-arm-host-capacity](https://github.com/hitrov/oci-arm-host-capacity) (PHP, archived)
- [HxX2/ocip](https://github.com/HxX2/ocip) (bash, cycles through availability domains)

This one is a small bash script that sets the boot volume size at launch, enforces the free-tier limit, and avoids duplicates.

## Disclaimer

Not affiliated with or endorsed by Oracle. You are responsible for what you create in your account and for checking Oracle's current pricing and Always Free terms. Check **Billing > Cost Analysis** after creating anything.

## License

[MIT](LICENSE)
