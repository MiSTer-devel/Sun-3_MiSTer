# SunOS 4.1.1 patches after U1 and the Y2K patch

Which of the patches on `sunos-4.1.1-patches.qic` (sun3arc's set: 174 patches
with a tar file, from `build/dist/sunos-4.1.1-patches/`) a 4.1.1_U1 Sun-3
with `y2kpatch-04` still lacks. Worked out on 2026-10-05 from each patch's
README (release, architecture, date, bug IDs, what it obsoletes) and tar,
against U1's file lists and the 4.1.1 distribution's sets.

| | patches |
|---|---|
| **not covered: security** | 18 |
| **not covered: other programs and libraries** | 40 |
| **not covered: OpenWindows 2.0** (installed with the rest of 4.1.1) | 4 |
| **not covered: kernel** (needs a kernel rebuild) | 16 |
| replaced by a later patch in the set, itself not covered | 14 |
| in U1 (inferred) | 35 |
| installed, or replaced by what is | 10 |
| not for this machine, or for software not installed | 37 |

## Installed (2026-10-05)

74 of the 78 not covered are on the MiSTer's disk, installed by the kit
`tools/sunos/mkpatchkit.py` makes ([install-sunos.md](install-sunos.md),
section 8), with a GENERIC kernel rebuilt from the patched objects. The Y2K
patch's files are unchanged. Left out:

* 100125-05: its 4.1.1 `in.telnetd` is older than U1's;
* 100191-02: for the unbundled SW dbx 1.0, and it conflicts with 100252-01;
* 100207-01: `/boot` for a second disk controller;
* 100240-01: its `make` is replaced by 100619-01's.

Of the rest, 100424-01's `ufs_inode.o` is not in the kernel (100622-01's is,
the owner's choice), nor 100201-06's two optional libc objects; 100482-06's
`securenets` waits for NIS to be set up.

## How "in U1" was decided

U1's release notes are not in the archive, and only one patch README names
U1. So a patch counts as in U1 when it is older than U1's build (7 November
1991) and U1 replaced the same sun3 files with its own newer builds. A
kernel patch older than U1 for an object U1 did not replace is **not** in U1:
U1 ships every object it changed. Patches made for SunOS 4.1 before 4.1.1
shipped (October 1990) count as not needed.

## Not covered: security

Drop-in replacements of programs, except where noted.

| patch | date | fixes | note |
|---|---|---|---|
| 100103-12 | Jun/29/93 | set file permissions to more secure mode | a script that tightens file permissions |
| 100184-02 | 14/Dec/90 | Openwindows 2.0: sv_xv_sel_svc and rpc can be used to gain access to system files |  |
| 100185-01 | 14/Dec/90 | /etc/rc.local can be used to destroy passwd | an edit to /etc/rc.local |
| 100201-06 | 05/Nov/92 | c2 jumbo patch | C2 security jumbo; newer than U1, but its login is older than the one in 100630-02 |
| 100224-13 | Oct/31/94 | /bin/mail jumbo patch |  |
| 100272-07 | Mar/16/94 | Security update for in.comsat |  |
| 100296-04 | 6/18/92 | netgroup exports to world |  |
| 100377-17 | Sep/09/94 | sendmail jumbo patch |  |
| 100383-06 | Jan/26/93 | rdist security and hard links enhancement, |  |
| 100421-03 | 30/Nov/92 | Jumbo rpc.rexd patch (remote execution, utmp, accounting) |  |
| 100482-06 | Oct/17/94 | ypserv and ypxfrd fix, plus DNS fix |  |
| 100593-03 | Mar/16/94 | Security update for dump |  |
| 100630-02 | Sep/17/93 | SunOS 4.x: SECURITY: methods to exploit login/su |  |
| 100909-03 | Aug/08/94 | Security update for syslogd |  |
| 101080-01 | Jun/09/93 | security problem with expreserve |  |
| 101480-01 | Mar/16/94 | Security update for in.talkd |  |
| 101481-01 | Mar/16/94 | Security update for shutdown |  |
| 101482-01 | Mar/16/94 | Security update for write |  |

## Not covered: other programs and libraries

| patch | date | fixes | note |
|---|---|---|---|
| 100125-05 | 08/July/91 | after telnet session aborts, new session gets previous output | only its in.rlogind: U1 has a newer in.telnetd |
| 100170-10 | Mar/19/93 | jumbo patch to fix various ld problems |  |
| 100178-08 | May/19/93 | inetd "broken server detection" breaks on fast machines |  |
| 100180-03 | 10-Feb-92 | cpp: cc option -I does not work for more than 47 paths |  |
| 100191-02 | 12/15/90 | dbx core dumps when sourcing files with aliases |  |
| 100207-01 | 22/Jan/91 | "boot" works for 1st disk controller only |  |
| 100236-01 | 6-Mar-91 | cxref fails in handling struct bit fields larger than 16 bits |  |
| 100240-01 | 24-Mar-91 | version "make" takes longer than 4.0.3 to process archives |  |
| 100249-07 | Mar/03/93 | automounter jumbo patch |  |
| 100252-01 | 22-Mar-91 | dbx:4.1.1: print of a large struct overflows stack |  |
| 100283-03 | 10/Sep/92 | in.routed mishandles gateways, multiple |  |
| 100286-02 | 23-Oct-91 | sort fails with n option on second field0--- |  |
| 100297-02 | 11/Dec/92 | Languages: Yacc's internal table size is too small for some applications |  |
| 100305-15 | Apr/11/94 | lpr Jumbo Patch |  |
| 100311-01 | 03-June-91 | restore i, wildcard chars. can't be used when adding files |  |
| 100342-03 | 18/June/92 | NIS client needs long recovery time if server reboots |  |
| 100344-01 | 06-Aug-91 | bourne shell: temporary file not removed if exec'ing other program |  |
| 100346-03 | 30-Jan-92 | patches for libxpg |  |
| 100372-02 | 08-Sept-92 | tfs and c2 do not work together |  |
| 100381-01 | 10-Sep-91 | du and tar bug fix for compatibility with VMS |  |
| 100390-01 | 24/Sept/1991 | DNS doesn't work properly with secondary name server |  |
| 100399-02 | 10-Oct-91 | csh memory leak tty gets EOF condition |  |
| 100407-09 | Jan/14/94 | accounting jumbo patch |  |
| 100408-01 | 3-Oct-91 | libcurses replacement with all 4.1.1 CTE patches |  |
| 100416-01 | 29/Oct/91 | tip fails can't synchronize with hayes |  |
| 100425-01 | 08/Nov/91 | whois gets host unknown when using the hard coded NICHOST |  |
| 100449-01 | 11/Dec/91 | Ex in open mode with '-' option won't display correctly |  |
| 100468-03 | 16/Oct/92 | rcp/rsh should use setsockopt to detect failed connection rsh uses old-style selects inste |  |
| 100549-01 | 27-Mar-92 | lex core dumps on large input files |  |
| 100556-02 | 8/Apr/92 | cpio data corruption when 2 inodes have same value |  |
| 100600-01 | 24/Apr/92 | fsck -p  won't check over 31 partitons |  |
| 100619-01 | 7/May/92 | make fails w/unexpected EOLN when include split across 8k |  |
| 100620-01 | 07/May/92 | Compiler generates incorrect code with -O2 or higher |  |
| 100634-01 | 26/May/92 | Select system call hangs when linked with lnbio & llwp libraries |  |
| 100650-02 | May/07/93 | ipcs aborts with "shmctl: Permission denied" |  |
| 100651-01 | undated | Cron dumps core & Cron dies when daylight savings time STARTS/STOPS |  |
| 100654-01 | undated | INSTALLTXT HAS UNDOCUMENTED LIMITS OF TAG SIZE 127 AND MESSAGE SIZE 255 |  |
| 100672-01 | 08/Jul/92 | static libc.a missing asynchronous I/O _aiocancel _aioread _aiowait |  |
| 101072-02 | Mar/30/94 | Non-related data filled the last block tarfile |  |
| 101783-02 | Jan/12/95 | jumbo patch for ld.so, ldd, and ldconfig |  |

## Not covered: OpenWindows 2.0

The 4.1.1 sun3 tapes carry OpenWindows 2.0, and suninstall's "all" put it on
the disk.

| patch | date | fixes | note |
|---|---|---|---|
| 100176-15 | 26-Mar-92 | OpenWindows 2.0: Patch release 2008-19 for X11-NeWS server |  |
| 100245-01 | 14-Mar-91 | Open Windows: 2.0 banding bug label centering bug |  |
| 100246-02 | 10-Aug-92 | OW 2.0: Panel button in monochrome causes core dump |  |
| 100247-18 | 10-Aug-92 | OW 2.0: XVIEW/2.0 CTE Jumbo Patch |  |

## Not covered: kernel

Each replaces objects in `/sys/sun3/OBJ`; a new kernel is then configured
and built (`config GENERIC`, `make`) and installed as `/vmunix`. They were
built for 4.1.1, and U1 is a 4.1.1 kernel, but U1 replaced some of the same
objects (`ufs_inode.o`, `str_io.o`, the tty and NFS objects): take each
patch's objects together and keep U1's otherwise. 100424-01 and 100622-01
both replace `ufs_inode.o`; 100622-01 does not list 100424-01's fix (bug
1063470). 100622-01's was taken.

Every patched object was checked against the kernel it goes into: each is
built for the 68020 (a.out machine type 2), and none needs a symbol that the
rest of the kernel lacks. 102231-01's `nfs_server.o` calls
`svckudp_dupdrop`, which its own `svc_kudp.o` brings. 100126-05's
`machdep.o` is the same as 4.1.1's, so only its `locore.o` and
`uipc_mbuf.o` are used.

| patch | date | fixes | note |
|---|---|---|---|
| 100126-05 | 25/March/91 | SunOS4.1 SunOS4.1_PSR_A SunOS4.1.1 SunOS4.0.3  MBUF PATCH |  |
| 100192-02 | Oct/22/93 | colormap is not correct when 128 colors are used |  |
| 100254-02 | 1-Apr-92 | panic: ttcompat: unexpected ioctl acknowledgment |  |
| 100303-02 | 06/Jan/92 | system freezes using loopback interface |  |
| 100338-05 | 4/Sep/92 | system crashes with assertion failed panic |  |
| 100359-08 | Jun/28/94 | streams jumbo patch |  |
| 100361-03 | 13/Feb/92 | server not responding due to limits of arp table |  |
| 100384-01 | 17/Sept/91 | panic data fault on rfs |  |
| 100412-02 | 06/Jan/93 | applications bind to same port if IP address supplied |  |
| 100424-01 | undated | SunOS 4.1.1; NFS/fsirand security fix | fsirand, and a ufs_inode.o that conflicts with 100622-01 |
| 100458-03 | Jan/27/93 | Setitimer sometimes fails to deliver |  |
| 100513-04 | Nov/09/93 | Jumbo tty patch |  |
| 100567-04 | 27/Oct/92 | mfree panic due to mbuf being freed twice, icmp redirects can be used to make a host drop  |  |
| 100622-01 | 18/Jun/92 | 4.1.1 UFS jumbo patch |  |
| 101817-01 | Jun/06/94 | rpc.lockd jumbo patch |  |
| 102231-01 | Dec/23/94 | NFS Jumbo Patch |  |

## Replaced by a later patch in the set

Apply the later one (named) instead.

* 100651-01: 100058-03, 100402-01, 100520-02
* 101817-01 (same fixes): 100075-11
* 102231-01: 100173-10
* 101783-02: 100257-05
* 100622-01: 100293-04, 100505-01
* 100178-08: 100341-01
* 101072-02: 100413-01
* 100482-06: 100465-02
* 100468-03: 100527-02
* 100305-15: 100598-01, 100696-01

## In U1 (inferred)

* file U1 replaced: 100133-01, 100141-03, 100210-01, 100251-01, 100256-01, 100268-02, 100300-01, 100335-01
* kernel object U1 replaced: 100149-03, 100159-01, 100179-01, 100188-01, 100198-01, 100211-02, 100225-02, 100228-02, 100233-01, 100244-02, 100250-01, 100255-01, 100259-01, 100262-01, 100265-01, 100273-01, 100279-01, 100280-02, 100281-01, 100310-02, 100313-01, 100315-01, 100357-01, 100375-01, 100414-01
* U1 replaced tmp_vnodeops.o, not tmp_tnode.o: 100174-06
* U1 replaced 4 of its 5 objects (not tcp_tlisubr.o): 100199-03

## Installed, or replaced by what is

* libc: superseded by the 100267-09 libc in y2kpatch-04: 100203-01, 100266-07
* inside y2kpatch-04 (its libc is built on it): 100267-09
* bar: y2kpatch-04 replaced bar with its own build: 100269-02, 100291-03, 100457-01
* the 4.1.1 tape's Patch_C++_2.0 / Patch_IPC sets, installed with 'all': C++_2.0, SunIPC
* U1 itself: Sun_4.1.1U1
* installed 2026-10-05: y2kpatch-04

## Not for this machine, or for software not installed

* SunOS 4.1 only (made before 4.1.1 shipped): 100071-01, 100072-01, 100074-01, 100076-01, 100101-02, 100137-01, 100147-01, 100177-01, 100217-01, 100234-01
* Sun-3x only: 100082-01, 100128-02, 100289-01, 100370-01, 100867-01
* 4.1 version of a 4.1.1 patch in the set: 100089-06, 100090-01, 100120-04, 100121-09, 100187-01
* FORTRAN, not installed: 100098-03, 100332-07
* SunLink X.25, not installed: 100106-02, 100328-18
* SPARCompilers 1.0 beta dbx: 100130-01
* unbundled C compiler, not installed: 100160-01, 100318-01
* FDDI, not installed: 100172-04
* Xylogics xd disk controller: 100274-02
* PC-NFS (DOS): 100287-05
* no sun3 build: 100304-02
* ie Ethernet: a 3/60 has le (LANCE): 100321-01, 100570-05
* placeholder (on hold / "use 100399"): 100331-01, 100374-01
* AnswerBook, not installed: 100409-02
* DECnet (DNI), not installed: 100472-02
