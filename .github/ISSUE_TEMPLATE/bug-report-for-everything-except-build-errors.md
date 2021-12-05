---
name: Bug report for everything except build errors
about: Use this template for all other bugs except those related to building heads
title: ''
labels: ''
assignees: ''

---

## Please identify some basic details to help process the report

### A. Provide Hardware Details

**1. What board are you using (see list of boards [here](https://github.com/eganonoa/heads/tree/master/boards))?**

**2. Does your computer have a dGPU or is it iGPU-only?**
- [ ] dGPU
- [ ] iGPU-only

**3. Who installed Heads on this computer?**
- [ ] Insurgo
- [ ] Nitrokey
- [ ] Purism
- [ ] Other provider
- [ ] Self-installed

**4. What PGP key is being used?**
- [ ] Librem Key
- [ ] Nitrokey Pro 2
- [ ] Nitrokey Storage
- [ ] Yubikey
- [ ] Other

**5. Are you using the PGP key to provide HOTP verification?**
- [ ] Yes
- [ ] No
- [ ] I don't know

### B. Identify how the board was flashed

**1. Is this problem related to updating heads or flashing it for the first time?**
- [ ] First-time flash
- [ ] Updating heads 

**2. If the problem is related to an update, how did you attempt to apply the update?**
- [ ] Using the Heads GUI
- [ ] Flashrom via the Recovery Shell
- [ ] External flashing

**3. How was Heads initially flashed**
- [ ] External flashing
- [ ] Internal-only / 1vyrain
- [ ] Don't know

**4. Was the board flashed with a maximized or non-maximized/legacy rom?**
- [ ] Maximized
- [ ] Non-maximized / legacy
- [ ] I don't know

**5. If Heads was externally flashed, was IFD unlocked?**
- [ ] Yes
- [ ] No
- [ ] Don't know

### C. Identify the rom related to this bug report

**1. Did you download or build the rom at issue in this bug report?**
- [ ] I downloaded it
- [ ] I built it

**2. If you downloaded your rom, where did you get it from?**
- [ ] Heads CircleCi
- [ ] Purism
- [ ] Nitrokey
- [ ] Somewhere else (please identify)

*Please provide the release number or otherwise identify the rom downloaded*

**3. If you built your rom, which repository:branch did you use?**
- [ ] Heads:Master
- [ ] Other (please identify)

**4. What version of coreboot did you use in building?**
- [ ] 4.8.1 (current default in heads:master)
- [ ] 4.13
- [ ] 4.14
- [ ] 4.15
- [ ] Other (please specify)
- [ ] I don't know

**5. In building the rom where did you get the blobs?**
- [ ] No blobs required
- [ ] Provided by the company that installed Heads on the device
- [ ] Extracted from a backup rom taken from this device
- [ ] Extracted from another backup rom taken from another device (please identify the board model)
- [ ] Extracted from the online bios using the automated tools provided in Heads
- [ ] I don't know

## Please describe the problem

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
