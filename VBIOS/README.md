# VBIOS/ — bundled vBIOS ROM dumps

`install_vbios_romfile()` in `vfio.sh` scans this folder for `*.rom` files and
auto-pins a matching dump into the guest GPU's libvirt hostdev (see the
"vBIOS ROM auto-injection" section in `vfio.sh`). A dump is only ever used if
it is verified to match the guest GPU — see `_vbios_rom_matches_gpu()`.

## Finding a dump for your card

`vfio.sh` can generate an exact search link for you: `install_vbios_romfile()`
prints one automatically (via `_vbios_techpowerup_url()`) whenever no matching
dump is found, derived ENTIRELY from your live hardware (not a hardcoded
example). It uses techpowerup's "Device Id" deep-link filter:

```
https://www.techpowerup.com/vgabios/?did=<VENDOR>-<DEVICE>-<SUBVENDOR>-<SUBDEVICE>
```

All four IDs are read straight from `/sys/bus/pci/devices/<bdf>/{vendor,device,subsystem_vendor,subsystem_device}`.
This is the most precise possible search: it matches the exact GPU chip AND
the exact board partner/SKU. Verified example for the bundled dump:
`https://www.techpowerup.com/vgabios/?did=1002-7550-1043-0614` returns
exactly the 3 "Asus RX 9070 16GB TUF OC" entries dated 2024-12-04, matching
the `ATOMBIOSBK-AMD VER023.008.000.068.000001` string embedded in
`tuf-gaming.rom` below.

If you'd rather browse manually, techpowerup's collection is also searchable
by brand/model/memory size at https://www.techpowerup.com/vgabios/, and
download filenames there follow the pattern
`<Vendor>.<Model>.<MemMB>.<YYMMDD>_<Rev>.rom` (e.g. `Asus.RX9070.16384.241204_1.rom`
for the bundled dump).

Drop a dump matching your exact card into this folder (any filename ending
in `.rom` works — the matcher reads the file's own embedded identity, not
its filename) and re-run `sudo ./vfio.sh --install-dynamic-binding` to have
it auto-detected and wired in.

## tuf-gaming.rom

Bundled dump for an ASUS TUF Gaming RX 9070 (16 GB), corresponding to
techpowerup's `Asus.RX9070.16384.241204_1.rom`.

- PCI vendor:device: `1002:7550` (AMD Navi 48 / RX 9070 family) — NOT present
  in this dump's own PCI Data Structure (PCIR pointer is `0x0000`), which is
  why `_vbios_rom_matches_gpu()` has a fallback tier for AMD ATOMBIOS dumps.
- Confirmed identity via `strings -n 4 tuf-gaming.rom`:
  ```
  ATOMBIOSBK-AMD VER023.008.000.068.000001
  ASUS_G2951200_XT_16GB_APM7912_P
  AMD ATOMBIOS
  TUF-RX9070
  PPIDTUF-RX9070-O16G-I3S//G295BP_R1.00X#241248215800539
  ```
- Auto-detector match result: `AMD ATOMBIOS dump, model token "RX9070" found
  (best-effort family match, not a strict PCI ID check -- verify by eye)`.
