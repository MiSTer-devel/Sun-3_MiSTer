# Sun-3 MiSTer core

A Sun-3/60C for MiSTer: [MiSTer-devel/Sun-3_MiSTer](https://github.com/MiSTer-devel/Sun-3_MiSTer).
* `docs/hardware.md` is the hardware contract.
* `docs/design-plan.md` is the plan, by phases.
* `README.md` is for users.

The machine comes from MelkhiorVintageComputing/Sun-3_FPGA (`rtl/sun3/`, its
changes listed in `rtl/sun3/README.md`). The MiSTer glue comes from
Sun-2_MiSTer. The network, the ID PROM and the disks' write buffer need a
Main_MiSTer with Sun support (`support/sun/`, the `sun-family` branch of
danifunker/Main_MiSTer).

## Rules

* **Work on `master`.** Ask before pushing.
* **`releases/` holds only what goes on a MiSTer**: the core
  (`Sun-3_YYYYMMDD.rbf`, the bitstream tested on the board), `MiSTer` (a
  Main_MiSTer with Sun support) and `boot0.rom` (the patched Rev 1.9 PROM,
  `make -C tools`). The README's "What you will need" says where each goes
  and what it was built from; keep the two in step.
* **A plain checkout builds with Quartus 17.0.2 alone.**
  * There are no submodules.
  * Third-party RTL sits in `rtl/vendor/` (`README.md` there), unmodified
    but for the local changes that README lists. This repository is its own:
    a change MiSTer needs is made here and recorded there, not held for
    upstream.
  * `sys/` is Template_MiSTer `3ea1134`, byte for byte (`.gitattributes`
    keeps it `-text`).
  * **Never disable framework features to save space**: no `MISTER_DISABLE_*`,
    `MISTER_SMALL_VBUF` or `MISTER_DOWNSCALE_NN`, no cuts to `sys/`. Find room
    in the machine's own RTL.
* **CPU and FPU changes are made by a Fable agent** (the Agent tool with
  `model: "fable"`), never directly: anything in `rtl/vendor/rd68021/`,
  `rtl/vendor/rd68884/`, or how `sun3_top.v` wires them.
* **The machine is fixed by `Sun-3.qsf`'s `VERILOG_MACRO` block**, every macro
  one `rtl/sun3/sun3_config.vh` documents. Runtime choices are OSD bits;
  their places are in `docs/design-plan.md`.
* **Every piece of MiSTer glue has a Verilator bench and a mutation script.**
  A "NOT CAUGHT" is a hole in the bench.
* **Quartus**: one build at a time, and kill it at 45 minutes. After every
  fit, check that `cpu_clk` is on a GCLK, and that timing is met with
  `cpu_clk` at 30 ns (`Sun-3.sdc` times it at the fastest OSD setting,
  33.33 MHz).
* **On a MiSTer**: check `/tmp/CORENAME` before loading a core or typing,
  and shut down whatever runs gracefully (halt SunOS with `fasthalt`) before
  taking it over. Test builds go in `/media/fat/_Unstable/`, media in
  `/media/fat/games/Sun-3/`.

## Commands (Linux or WSL, Verilator 5.020)

| | |
|---|---|
| `make -C tools` / `all-roms` / `fetch` | the stock 3/60 PROMs from sun3arc into `build/rom/`, SHA-256 checked; the patched `noparity` image (`boot0.rom`) and the simulation's `fast` one |
| `make -C tb/verilator` | the glue benches: sdram, block, kbd_mouse, bell, kbm_scc, tod, mt02, cg4, cg4_scanout, eeprom, si (the SCSI DMA against the old byte-per-cycle engine), vint (level 4's source, with the interrupt PAL and the P4 register), enet (the network's DDR3 mailbox, between Wish7990's MII blocks and Main's daemon played by the bench), cpuclk (the OSD's CPU clock: the PLL's counter rewritten in reset, against `pll_stub.sv`'s PLL and `pll_cfg`) |
| `bash tb/verilator/mutate_<x>.sh` | mutation checks: sdram, kbm, bell, tod, mt02, cg4, cg4_scanout, eeprom, si, vint, enet, cpuclk, cpu_fpu |
| `make -C tb/verilator tb_cpu_fpu` | RD68021 + RD68884 against the 1,320-program CPU+FPU corpus a real Mac II passed |
| `make -C tb/verilator tb_emu [TIMEOUT_MS=] [DISK=] [DISK1=] [EEPROM=] [KEYS=] [SIMARGS=]` | the whole core (`Sun-3.sv` with `files.qip` and the `.qsf`'s macros): PROM loader, SDRAM, scan-out, keyboard. It writes `screen_*.ppm` (24-bit), `console.log` and a log in `run_tb_emu/`. With the `fast` PROM the banner comes at ~1 s simulated, and `+eeprom_boot=st` boots the tape to munix by ~2.6 s. Its plusargs (`+tape=`, `+eeprom=` and `+eeprom_save=`, `+status=1000` for colour off, `+status=4000` for 33 MHz, `+trace_tape`, `+trace_cg4`, `+trace_scsi`, `+trace_vd`, `+watch=`, `+pctrace_from=`, `+memdump=`, `+screen_stats`) are listed in `tb_emu.sv`'s header. `EMU_OBJ=` builds a second copy while one runs |
| `python3 tools/mktape -o build/tapes/X.qic <dir>` | a tape image from a SunOS sun3 distribution (sun3arc `maketape` layout, or `tapeN/` per-file dumps) |
| `python3 tools/mktape --disk build/disks/sd0-1g.img --size 1024 --root 32` | an empty, labelled 1 GB disk to install onto ([docs/install-sunos.md](docs/install-sunos.md)); tapes built by `mktape` know it in `format.dat` |
| `python3 tools/sunos/mkpatchkit.py` | the kit (`build/dist/patchkit-tape/`, for `mktape`) that installs the 74 SunOS patches U1 and the Y2K patch lack ([docs/sunos-patches.md](docs/sunos-patches.md), install-sunos.md 8) |

SunOS itself is not in the repository: unpack the distributions (the sun3arc
4.1.1 set, 4.1.1_U1, the patches) into `build/dist/`, which git ignores, as
are the PROM images, disks and tapes the tools make under `build/`.

## Traps

* **On Windows, `wsl -- bash -c '... $VAR ...'` loses `$VAR`**: the
  variables are gone before bash sees them, and a `for t in ...; make $t`
  ran `make` with no target. Put anything with variables in a script file
  and run `wsl -- bash /mnt/c/.../script.sh`.
* **A backslash-newline inside a heredoc in the Bash tool becomes a tab.**
  Edit Makefiles with the Edit tool.
* **A Windows checkout with `core.autocrlf=true` is CRLF.** Python edits must
  handle `\r\n`, and scripts run in WSL need LF (`.gitattributes` forces
  `*.sh`, `*.py` and Makefiles). Windows Python's `open(p, 'w')` writes CRLF,
  and bash then fails on the `\r` (`syntax error near unexpected token
  $'{\r'`): write bytes (`'wb'`).
* **tb_emu's frame dumps are 3 MB each** (24-bit PPM), so a PROM drawing text
  slows the run tenfold. `+screen_ms` (default 200) limits them.
* **tb_emu's log is buffered**: `sim.log` stays empty for a while when stdout
  is a file. The heartbeat lines flush it in time.
* **The PROM leaves `bp_argv[2..7]` as RAM had them**, and SunOS 4.1.1's
  tape boot program reads all seven. Stock PROMs fill RAM with 0xffffffff at
  power-on, which it takes as a string pointer, and it then copied low memory
  over itself. The noparity patch sets make that fill zero (`zeroRamInit`),
  and `sdram_model.sv` reads never-written cells as zero to match.
* **Keys typed before the PROM asks are lost** (it only reads the keyboard at
  "press any key"), so `+keys` timing is fragile. Use `+eeprom_boot=st`.
* **Verilator 5.020 got `pll_stub.sv`'s computed delays (`#(expr)`, in its
  1 ps) 1000 times too long under a 1 ns bench**: the clocks ran at a
  thousandth. Benches that use it are 1 ps throughout, as `tb_emu` is.
* **The ICM7170 model came with three bugs.** It turned the year at the end of
  November, never advanced the weekday, and a reset stopped it. Each is fixed,
  and `tb_mister_tod` / `mutate_tod.sh` guard them.
* **Main_MiSTer saves a core's OSD settings only from its System page**
  (*Save settings*); closing the OSD or its *Reset* saves nothing.
