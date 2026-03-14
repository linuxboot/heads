---
name: Bug report for everything except build errors
about: Use this template for all other bugs except those related to building heads
title: ''
labels: ''
assignees: ''

---

## Before filing a bug report

**⚠️ Check if your issue is already fixed in master!**

1. Get your Heads version from the running system: go to **Options → System Information** and note the full version string (including git commit hash).
2. Compare your version with the current [Heads master branch](https://github.com/linuxboot/heads/commits/master). You can check the diff at:
   `https://github.com/linuxboot/heads/compare/<your-commit-hash>...master`
   - If the bug is already fixed in master, **please upgrade** to the latest release instead of filing a report.
   - If you received your device from a vendor (Nitrokey, Insurgo, Purism, etc.) and the fix is in master but not in their release, **please file the bug with your vendor** so they can do a bugfix release.

---

## Please identify some basic details to help process the report

### A. Provide Hardware Details

1. What board are you using? (Choose from the list of boards [here](https://github.com/linuxboot/heads/tree/master/boards))

2. Does your computer have a dGPU or is it iGPU-only?
    - [ ] dGPU (Distinct GPU other then internal GPU)
    - [ ] iGPU-only (Internal GPU, normally Intel GPU)

3. Who installed Heads on this computer?
    - [ ] Insurgo (Issues to be reported at https://github.com/linuxboot/heads/issues)
    - [ ] Nitrokey (Issues to be reported at https://github.com/Nitrokey/heads/issues)
    - [ ] Purism (Issues to be reported at https://source.puri.sm/firmware/pureboot/-/issues)
    - [ ] Novacustom (Issues to be reported at https://github.com/Dasharo/dasharo-issues)
    - [ ] HardnenedVault (Issues to be reported at https://github.com/hardenedvault/vaultboot/issues)
    - [ ] Other provider
    - [ ] Self-installed

4. What PGP key is being used?
    - [ ] Librem Key (Nitrokey Pro 2 rebranded)
    - [ ] Nitrokey Pro
    - [ ] Nitrokey Pro 2
    - [ ] Nitrokey 3 NFC
    - [ ] Nitrokey 3 NFC Mini
    - [ ] Nitrokey Storage
    - [ ] Nitrokey Storage 2
    - [ ] Yubikey
    - [ ] Other

5. Are you using the PGP key to provide HOTP verification?
    - [ ] Yes
    - [ ] No
    - [ ] I don't know

### B. Identify how the board was flashed

1. Is this problem related to updating heads or flashing it for the first time?
    - [ ] First-time flash
    - [ ] Updating heads 

2. If the problem is related to an update, how did you attempt to apply the update?
    - [ ] Using the Heads menus
    - [ ] Flashrom via the Recovery Shell
    - [ ] External flashing

3. How was Heads initially flashed?
    - [ ] External flashing
    - [ ] Internal-only / 1vyprep+1vyrain / skulls
    - [ ] Don't know

4. Was the board flashed with a maximized or non-maximized/legacy rom?
    - [ ] Maximized
    - [ ] Non-maximized / legacy
    - [ ] I don't know

5. If Heads was externally flashed, was IFD unlocked?
    - [ ] Yes
    - [ ] No
    - [ ] Don't know

### C. Identify the rom related to this bug report

1. Did you download or build the rom at issue in this bug report?
    - [ ] I downloaded it
    - [ ] I built it

2. If you downloaded your rom, where did you get it from?
    - [ ] Heads CircleCi
    - [ ] Purism
    - [ ] Nitrokey
    - [ ] Dasharo DTS (Novacustom)
    - [ ] Somewhere else (please identify)

    *Please provide the release number or otherwise identify the rom downloaded*

3. If you built your rom, which repository:branch did you use?
    - [ ] Heads:Master
    - [ ] Other (please identify)

4. What version of Heads/coreboot are you running?
   - Navigate to **Options → System Information** on the running device and paste the **full version string** here (including the git commit hash).
   - Alternatively, provide the GitHub commit ID if building from source.

5. In building the rom, where did you get the blobs?
    - [ ] No blobs required
    - [ ] Provided by the company that installed Heads on the device
    - [ ] Extracted from a backup rom taken from this device
    - [ ] Extracted from another backup rom taken from another device (please identify the board model)
    - [ ] Extracted from the online bios using the automated tools provided in Heads
    - [ ] I don't know

## Please describe the problem

**⚠️ Debug traces are required for all bug reports!**

Before filling in the details below, please capture debug/trace output from Heads. Follow the instructions at:
👉 https://osresearch.net/Porting/#enabling-debug--trace-from-heads-gui

Paste the debug output in the **Additional context** section below (or attach as a file).

**Describe the bug**
A clear and concise description of what the bug is.

**To Reproduce**
Steps to reproduce the behavior:
1. Go to '...'
2. Click on '....'
3. Scroll down to '....'
4. See error

**Expected behavior**
A clear and concise description of what you expected to happen.

**Screenshots**
If applicable, add screenshots to help explain your problem.

**Additional context**
Add any other context about the problem here.
