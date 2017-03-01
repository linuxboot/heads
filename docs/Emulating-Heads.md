Generate the `qemu.rom` image:

```
make BOARD=qemu
```

Boot it in qemu:

```
qemu-system-x86_64 -machine q35 -bios qemu.rom
```

Issues with emulation:
* TPM is not available
* Xen won't start dom0 correctly, but it is sufficient to test that the `initrd.cpio` file was correctly generated
* This also lets us test Xen patches for legacy-free systems
* SATA controller sometimes takes minutes to timeout?