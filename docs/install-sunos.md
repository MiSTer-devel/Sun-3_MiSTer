# Installing SunOS 4.1.1 on the MiSTer Sun-3

This installs SunOS 4.1.1 onto an empty 1 GB disk from the release tapes, the
way it was done on a real 3/60:
1. boot the tape;
2. let MUNIX, its RAM-disk kernel, copy the miniroot onto the disk's swap
   partition;
3. boot the miniroot and run `suninstall`.

All of it has been done on a MiSTer (2026-10-04), with the screens quoted
from it. The whole install, both tapes and every package, takes about two
and a quarter hours. Sections 6 to 8 then bring it to 4.1.1_U1 with the
Y2K patch and the later patches (2026-10-05).

## 1. Make the images, on a PC

`tools/mktape` needs Python 3 and nothing else (and 7-Zip or `unrar` to read
a `.rar` directly).

```sh
tools/mktape -o sunos-4.1.1-sun3.qic <the 4.1.1 distribution's sun3 directory>
tools/mktape --disk sd0-1g.img --size 1024 --root 32
```

* A `.qic` is the whole set: both volumes, every file in order. The OSD's
  *Tape volume* picks which cartridge is in the drive.
* `mktape` changes one thing on the way. The `/etc/format.dat` in MUNIX's RAM
  disk and in the miniroot learns the 256, 512 and 1024 MB disks `--size`
  makes, so that `format` labels them without asking. No tape file changes
  size.
* `sd0-1g.img` is 1 GiB, 16 heads of 64 sectors on 2048 cylinders, two of
  them alternates. It is empty but already labelled, so `format` is not
  needed:

  | partition | size | use |
  |---|---|---|
  | `a` | 31.5 MB | `/` |
  | `b` | 63.5 MB | swap, and the miniroot during the install |
  | `g` | 928 MB | `/usr` |

  Until SunOS is installed, its boot block says so and returns to the
  monitor. 1 GiB is the most the PROM's six-byte SCSI commands reach.
  `a` and `b` are kept a cylinder off any multiple of 32 MB, so 32 comes out
  as 31.5 (the standalone driver keeps a partition's size in 16 bits).

Copy the tape and the disk to `/media/fat/games/Sun-3/`, with `boot0.rom`.
The disk can also be made on the MiSTer itself, from just its first 8 KB:

```sh
head -c 8192 sd0-1g.img > sd0-head.bin          # on the PC; copy it over
dd if=/dev/zero of=sd0-1g.img bs=1M count=1024  # on the MiSTer
dd if=sd0-head.bin of=sd0-1g.img conv=notrunc
```

## 2. Mount them

In the OSD (F12):
* *SCSI disk ID 0 (sd0)*: `sd0-1g.img`;
* *Tape (st0)*: `sunos-4.1.1-sun3.qic`, with *Tape volume* `1`;
* optionally *EEPROM* (see the README).

Then *Reset*. The PROM auto-boots the disk:

```
EEPROM boot device...sd(0,0,0)

This disk is labelled but has no SunOS on it yet.
To install from the tape in st0:  b st()
>
```

The keyboard is a Sun one on a PC: **hold Right Alt + F1 and press A** for the
Sun's `L1-A`, the abort back to this `>` prompt.

## 3. Boot the tape and put the miniroot on the disk

```
> b st()
Boot: st(0,0,0)
Size: 507912+123920+79144 bytes
SunOS Release 4.1.1 (MUNIX) #1: Sat Oct 13 08:59:27 PDT 1990
...
sd0 at si0 slave 0
sd0:  <MiSTer 1024MB cyl 2046 alt 2 hd 16 sec 64>
...
rd: reading 192, 8192 byte blocks: ......done
root on rd0a fstype 4.2

What would you like to do?
  1 - install SunOS mini-root
  2 - exit to single user shell
Enter a 1 or 2: 1
Beginning system installation - probing for disks.
?
installing miniroot on disk "sd0", (only disk found).
Do you want to format and/or label disk "sd0"?
  1 - yes, run format
  2 - no, continue with loading miniroot
  3 - no, exit to single user shell
Enter a 1, 2, or 3: 2
checking writeability of /dev/rsd0b
Extracting miniroot ...
using tape "st0"
Extracting miniroot (takes a couple of minutes) ...
70+0 records in
70+0 records out

Mini-root installation complete.

What would you like to do?
  1 - reboot using the just-installed miniroot
  2 - exit into single user shell
Enter a 1 or 2: 1
```

The tape's own open waits ten seconds for the drive, as on a real 3/60. The
`?` is the install script's `ed` finding nothing to change; it does no harm.

## 4. The miniroot and suninstall

```
Boot: sd(0,0,1) -sw
root on sd0b fstype 4.2
Boot: vmunix
SunOS Release 4.1.1 (MINIROOT) #1: Sat Oct 13 08:07:21 PDT 1990
...
root on sd0b fstype 4.2
swap on sd0b fstype spec size 65024K
# TERM=sun; export TERM
# suninstall
```

Choose **2, Custom installation**. It asks for the time zone (for example
`US/Eastern`) and whether the date is right; answer `y` whatever it shows (see
"The clock" below). Then the main menu. In the forms, **x** selects,
**space** moves to the next choice, **Return** ends a typed field, Ctrl-N and
Ctrl-P move between fields, and Backspace erases.

* **assign host information**: a name (Backspace over `noname`); type
  *standalone*; Ethernet interface **none** (the network is not built yet);
  Reboot after completed `n`. `y` and Return to "Are you finished".
* **assign disk information**: select `sd0`; Disk Label **use existing** (the
  one `mktape` wrote); Free Hog **g**; Mbytes. In the table: `a` mount point
  `/`, preserve `n`; Return past `b` and `c`; `g` mount point `/usr`,
  preserve `n`:

  ```
  PARTITION START_CYL BLOCKS    SIZE     MOUNT PT        PRESERVE(Y/N)
      a     0         64512     32       /               n
      b     63        130048    66
      c     0         2095104   1072
      g     190       1900544   973      /usr            n
  ```

  (SIZE is in millions of bytes.) `y` to "Ok to use this partition table",
  `y` to "finished".
* **assign software information**: *add new release*, Return at "insert the
  release media", Media Device **st0**, Location **local**, `y` to read the
  table of contents ("You have the sunos 4.1.1 sun3 media loaded"), Choice
  **all**, the default paths, `y` to the configuration and to "finished".
* **start the installation**:

  ```
  System Installation Begins:
  Label disk(s):
  Create/check filesystems:
  Creating new filesystem for / on sd0a
  Creating new filesystem for /usr on sd0g
  Setting up server file system for services
  Extracting the sunos 4.1.1 sun3 'root' media file.
  Extracting the sunos 4.1.1 sun3 'usr' media file.
  ```

  `Label disk(s)` asks nothing: `format` knows the disk from the tape's
  `format.dat`. `newfs` on the 973 MB `/usr` takes about twenty minutes.

  Then each software set comes off the tape, uncompressed on the Sun:

  ```
  Extracting the sunos 4.1.1 sun3 'usr' media file.
  1136+1 records in
  22722+0 records out
  Extracting the sunos 4.1.1 sun3 'Kvm' media file.
  ```

  `usr` takes about 23 minutes, mostly the thousands of small files it
  creates; `Kvm`, two. At the end of the first cartridge:

  ```
  You have sunos 4.1.1 sun3 release media volume 1 mounted
  Please mount sunos 4.1.1 sun3 release media volume 2
  Press <return> to continue
  ```

  Open the OSD, set *Tape volume* to `2`, close it, and press Return. It
  ends:

  ```
  Boot block installed
  Making device nodes
  Cleaning disk(s):
          / (/dev/sd0a)
  /dev/rsd0a: 785 files, 2270 used, 27985 free
          /usr (/dev/sd0g)
  /dev/rsd0g: 10737 files, 111659 used, 781059 free

  System installation completed:
  #
  ```

## 5. Boot the installed system

The miniroot has no `halt`: type `sync` twice, then L1-A. At `>`, `b sd()`, or
reset: the PROM's auto-boot now finds the boot block `installboot` wrote.

```
EEPROM boot device...sd(0,0,0)
root on sd0a fstype 4.2
Boot: vmunix
SunOS Release 4.1.1 (GENERIC) #1: Sat Oct 13 06:05:48 PDT 1990
...
cgfour0 at obmem 0xff300000 pri 4
bwtwo0 at obmem 0xff000000 pri 4
root on sd0a fstype 4.2
swap on sd0b fstype spec size 65024K
checking filesystems
...
sun3 login: root
sun3# df
Filesystem            kbytes    used   avail capacity  Mounted on
/dev/sd0a              30255    2430   24799     9%    /
/dev/sd0g             892718  111659  691787    14%    /usr
```

`root` has no password; set one with `passwd`. **Stop it with `fasthalt`**
(or `halt`), never by resetting or leaving the core while it runs:

```
sun3# fasthalt
syncing file systems... done
Halted
>
```

Back up the disk image now: a copy of it is a complete, bootable copy of the
machine.

## 6. 4.1.1_U1

`sunos-4.1.1u1-sun3.qic` (made by `tools/mktape` from the U1 tape's six
files) updates 4.1.1: a new kernel, libc 0.15.2 and some commands. It wants
single user. Mount the tape (OSD slot 2 on a core with the second disk,
slot 1 without), boot, and as root:

    cp /vmunix /vmunix.411            # a kernel the PROM can boot if need be
    shutdown now
    # mkdir /var/tmp/unbundled
    # cd /var/tmp/unbundled
    # mt -f /dev/nrst0 rew
    # mt -f /dev/nrst0 fsf 1
    # tar xvf /dev/nrst0
    # ./install_unbundled -dst0

It surveys the packages for a couple of minutes, then asks: continue (`y`),
save the files it replaces (`y`, partition `/usr`, a directory such as
`U1save`, create it `y`), continue (`y`), extract the new GENERIC kernel
(`y`; it keeps the old one as `/vmunix.GENERIC`), and reboot (`y`). The
reboot checks the disks, and `uname -a` then says `SunOS sun3 4.1.1_U1 1
sun3`. On the MiSTer the whole install took about 15 minutes.

## 7. The Y2K patch

sun3arc's `y2kpatch-04` (on `sunos-4.1.1-patches.qic`, a single tar of all
the patches) fixes `date`, `w`, `at`, `eeprom`, `touch`, `bar`, `passwd`
and the troff macros past 2000, and brings a shared libc built on the libc
jumbo patch 100267-09. Extract it (tar reads the whole 139 MB tape, about
four minutes):

    mkdir /home/y2k; cd /home/y2k
    tar xvf /dev/rst0 patches/y2kpatch-04.tar patches/y2kpatch-04.README
    tar xf patches/y2kpatch-04.tar; cd y2kpatch

and follow its README. On a 4.1.1_U1 system the shared libcs U1 left are
0.15.2 and 1.15.2, so the patch's become `/usr/lib/libc.so.0.15.3` and
`/usr/5lib/libc.so.1.15.3`. Install the patch's `libc.sa015` and
`libc.sa115` beside them as `libc.sa.0.15.3` and `libc.sa.1.15.3`, as the
jumbo patch's own README does (the README of `y2kpatch` leaves them out,
and they differ from U1's), and `ranlib` them, or `ld` warns that their
table of contents is out of date. Run `ldconfig` and test with `date` and
`ping localhost` before going on. root's shell, bash, is linked statically,
so it keeps working whatever happens to the shared libc.

## 8. The other patches

[sunos-patches.md](sunos-patches.md) sorts the 174 patches on
`sunos-4.1.1-patches.qic`; 78 are not covered by U1 or the Y2K patch.
`tools/sunos/mkpatchkit.py` turns 74 of them into a kit: `install.sh` for
the programs and libraries, `kernel.sh` for the kernel objects and a new
kernel. Each file it replaces stays beside the new one as
`<file>.pre-<patch>`, and it touches none of the Y2K patch's files (it sums
them before and after). On a PC:

    python3 tools/sunos/mkpatchkit.py
    python3 tools/mktape -o build/tapes/sunos-4.1.1-patchkit.qic build/dist/patchkit-tape

Mount that tape and boot. As root, in single user:

    shutdown now
    # cd /home; tar xf /dev/rst0
    # /sbin/sh /home/kit/install.sh 2>&1 | tee /home/kit/install.log
    # /sbin/sh /home/kit/kernel.sh 2>&1 | tee /home/kit/kernel.log
    # cd /; sync; sync; reboot vmunix.new

`install.sh` took 17 minutes on the MiSTer, seven of them in 100103's
`4.1secure.sh`, which tightens the modes and owners of 297 files and
directories. It swaps `ld.so` in one `mv`, because every dynamic program,
`mv` included, maps it. `kernel.sh` puts 39 objects in `/sys/sun3/OBJ`,
configures GENERIC and builds it as `/vmunix.new` (8 minutes, with
`make depend`). While the system runs on
`vmunix.new`, `ps` says it "could not read kernel VM", because it reads
`/vmunix`. When the new kernel has come up, keep U1's and make it the
default:

    ln /vmunix /vmunix.U1; mv /vmunix.new /vmunix

then reboot. To go back, boot `vmunix.U1` from the PROM
(`b sd(0,0,0)vmunix.U1`).

Left out:
* **100125-05**: its 4.1.1 `in.telnetd` is older than U1's (its
  `in.rlogind` is for 4.1 and 4.0.3 only).
* **100191-02**: the unbundled SW dbx 1.0's `dbx`; it conflicts with
  100252-01, the bundled one's patch, which is installed.
* **100207-01**: `/boot` for a second disk controller; it needs
  `installboot`, and the 3/60 has one SCSI controller.
* **100240-01**: `make`; 100619-01's newer `make` replaces it.
* **100424-01's `ufs_inode.o`**: 100622-01 (the UFS jumbo) replaces the same
  object, and its newer one was taken. 100424-01's `fsirand` is installed.
* **100201-06's `getauditflags.o` and `getpwaent.o`**: only for linking
  programs that call those two functions; libc itself is unchanged.
* **100482-06's `/var/yp/securenets`**: only where NIS is set up.

Lines typed at the console are cut at 256 characters (the tty's limit), so
type long commands into a file, or write them into a script.

## A second disk

OSD slot 1 is the disk at SCSI ID 1, which SunOS calls `sd2`. An empty
labelled image for it, with one 1019 MB partition `a` (and 4 MB of swap on
`b`):

    python3 tools/mktape --disk build/disks/sd2-1g.img --size 1024 --swap 4

Only its first two sectors hold anything, so on the MiSTer it can be made
with `dd if=/dev/zero bs=1M count=1024` and those 1024 bytes written over the
start (`conv=notrunc`), rather than copying 1 GB. Choose it in slot 1, boot,
and the kernel reports `sd2: <MiSTer 1024MB cyl 2046 alt 2 hd 16 sec 64>`.
Then, as root:

    newfs -i 8192 /dev/rsd2a
    mkdir /home2; mount /dev/sd2a /home2

On the MiSTer the `newfs` took 84 s, and copying `/usr/include` (3 MB of
small files) 103 s. One inode per 8 KB, a quarter of `newfs`'s default, is
still about 130,000, and makes `fsck` quicker. To mount it at every boot, add

    /dev/sd2a /home2 4.2 rw 1 3

to `/etc/fstab`. Only do this while slot 1 always has the image: with the
slot empty, the boot's `fsck` fails and stops in single user.

## The clock

SunOS keeps UTC in the clock chip and applies its time zone on top, and
MiSTer gives the core local time. So with a time zone set, the Sun shows the
wrong hour: with `US/Eastern` and MiSTer at 19:27 EDT, suninstall offered
`15:27:34 EDT`. Answer `y` there anyway: setting the "right" time would put
the chip four hours ahead, and the next core load would set it back, a clock
going backwards, which `fsck` takes for damage. Once the system runs, make
its zone GMT, so that it shows MiSTer's local time as it is given (as on the
Sun-2):

    rm /usr/share/lib/zoneinfo/localtime
    ln /usr/share/lib/zoneinfo/GMT /usr/share/lib/zoneinfo/localtime

`date` then shows MiSTer's local time, labelled GMT.

## Main_MiSTer

A Main_MiSTer with the Sun family's Sun-3 support (`support/sun/`, branch
`sun-family`) makes two differences. It buffers the disks' writes, which a
stock Main makes one 512-byte synchronous write at a time. And it gives the
machine an ID PROM made from the MiSTer's own Ethernet address (or
`games/Sun-3/boot1.rom`), so each MiSTer's Sun has its own Ethernet address
and host ID. The install above ran on a stock Main; the installed system
then booted on the Sun family's.
