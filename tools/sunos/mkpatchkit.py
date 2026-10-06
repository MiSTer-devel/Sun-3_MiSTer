#!/usr/bin/env python3
#
# Build the kit that installs the SunOS 4.1.1 patches docs/sunos-patches.md
# lists as not covered, on a 4.1.1_U1 Sun-3 with y2kpatch-04
# (docs/install-sunos.md, 8).  From sun3arc's patch set (each patch a .tar and
# a .README) it writes
#
#     <out>/kit/install.sh    the programs and libraries, in single user
#     <out>/kit/kernel.sh     the kernel objects, then a GENERIC kernel
#     <out>/kit/patches/      the tar and README of each patch they use
#     <out>/01-kit.tar        all of kit/, for tools/mktape
#
# The file lists, modes and owners come from each patch's README.  The
# y2kpatch-04 files are never touched: the script refuses a destination among
# them, and install.sh checks their sums before and after.
#
#     python3 tools/sunos/mkpatchkit.py [patches-dir [out-dir]]
#     python3 tools/mktape -o build/tapes/sunos-4.1.1-patchkit.qic build/dist/patchkit-tape

import os, sys, tarfile, shutil
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'build/dist/sunos-4.1.1-patches')
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'build/dist/patchkit-tape')
KIT = os.path.join(OUT, 'kit')
D = D.rstrip('/') + '/'
R = {}

def member(pid, suffix):
    if pid not in R:
        with tarfile.open(D + pid + '.tar') as t:
            R[pid] = [m[2:] if m.startswith('./') else m for m in t.getnames()]
    ms = [m for m in R[pid] if m == suffix or m.endswith('/' + suffix)]
    assert len(ms) == 1, (pid, suffix, ms)
    return ms[0]

# (patch, file in its tar, destination, mode, owner[.group]) -- from each README
U = [
 ('100170-10', 'sun3/ld', '/usr/bin/ld', '755', ''),
 ('100176-15', 'sun3/xnews', '/usr/openwin/bin/xnews', '', ''),
 ('100178-08', 'sun3/4.1.1/inetd', '/usr/etc/inetd', '755', ''),
 ('100180-03', 'sun3/cpp', '/usr/lib/cpp', '755', ''),
 ('100184-02', 'sun3/sv_xv_sel_svc', '/usr/openwin/bin/xview/sv_xv_sel_svc', '', ''),
 ('100201-06', 'sun3/4.1.1/login', '/usr/bin/login', '4755', 'root.staff'),
 ('100201-06', 'sun3/4.1.1/rpc.pwdauthd', '/usr/etc/rpc.pwdauthd', '755', 'root.staff'),
 ('100201-06', 'sun3/4.1.1/rpc.yppasswdd', '/usr/etc/rpc.yppasswdd', '755', 'root.staff'),
 ('100224-13', 'sun3/4.1.1/mail', '/usr/bin/mail', '4111', ''),
 ('100224-13', 'sun3/4.1.1/rmail', '/usr/bin/rmail', '111', ''),
 ('100236-01', 'sun3/cxref', '/usr/bin/cxref', '', ''),
 ('100236-01', 'sun3/xpass', '/usr/lib/xpass', '', ''),
 ('100245-01', 'sun3/olwm', '/usr/openwin/bin/olwm', '', ''),
 ('100246-02', 'sun3/libolgx.a', '/usr/openwin/lib/libolgx.a', '', ''),
 ('100246-02', 'sun3/libolgx.so.3.0', '/usr/openwin/lib/libolgx.so.3.0', '', ''),
 ('100247-18', 'sun3/libxview.a', '/usr/openwin/lib/libxview.a', '', ''),
 ('100247-18', 'sun3/libxview.so.3.0', '/usr/openwin/lib/libxview.so.3.0', '', ''),
 ('100247-18', 'sun3/libxview.sa.3.0', '/usr/openwin/lib/libxview.sa.3.0', '', ''),
 ('100249-07', 'sun3/4.1.1/automount', '/usr/etc/automount', '755', 'root.staff'),
 ('100252-01', 'sun3/dbx', '/usr/ucb/dbx', '', ''),
 ('100272-07', 'sun3/4.1.1/in.comsat', '/usr/etc/in.comsat', '755', 'root.staff'),
 ('100283-03', 'sun3/4.1.1/in.routed', '/usr/etc/in.routed', '', ''),
 ('100286-02', 'sun3/sort', '/usr/bin/sort', '', ''),
 ('100296-04', 'sun3/4.1.1/rpc.mountd', '/usr/etc/rpc.mountd', '755', 'root.staff'),
 ('100297-02', 'sun3/yacc', '/usr/bin/yacc', '755', ''),
 ('100305-15', 'sun3/4.1.1/lpd', '/usr/lib/lpd', '6711', 'root.daemon'),
 ('100305-15', 'sun3/4.1.1/lpr', '/usr/ucb/lpr', '6711', 'root.daemon'),
 ('100305-15', 'sun3/4.1.1/lprm', '/usr/ucb/lprm', '6711', 'root.daemon'),
 ('100305-15', 'sun3/4.1.1/lpq', '/usr/ucb/lpq', '6711', 'root.daemon'),
 ('100305-15', 'sun3/4.1.1/lpc', '/usr/etc/lpc', '2711', 'root.daemon'),
 ('100305-15', 'sun3/4.1.1/pac', '/usr/etc/pac', '755', 'root.staff'),
 ('100305-15', 'sun3/4.1.1/lpstat', '/usr/bin/lpstat', '6711', 'root.daemon'),
 ('100305-15', 'sun3/4.1.1/cancel', '/usr/bin/cancel', '6711', 'root.daemon'),
 ('100311-01', 'sun3/restore', '/usr/etc/restore', '', ''),
 ('100342-03', 'sun3/4.1.1/ypbind', '/usr/etc/ypbind', '755', 'root'),
 ('100344-01', 'sun3/sh', '/usr/bin/sh', '', ''),
 ('100346-03', 'sun3/libxpg.a', '/usr/xpg2lib/libxpg.a', '', ''),
 ('100346-03', 'sun3/libxpg_p.a', '/usr/xpg2lib/libxpg_p.a', '', ''),
 ('100361-03', 'sun3/4.1.1/arp', '/usr/etc/arp', '', ''),
 ('100372-02', 'sun3/4.1.1/tfsd', '/usr/etc/tfsd', '755', 'root.staff'),
 ('100377-17', 'sun3/4.1.1/sendmail', '/usr/lib/sendmail', '4551', 'root.staff'),
 ('100377-17', 'sun3/4.1.1/sendmail.mx', '/usr/lib/sendmail.mx', '4551', 'root.staff'),
 ('100377-17', 'sendmail.main.cf', '/usr/lib/sendmail.main.cf', '', ''),
 ('100377-17', 'sendmail.subsidiary.cf', '/usr/lib/sendmail.subsidiary.cf', '', ''),
 ('100381-01', 'sun3/du', '/usr/bin/du', '755', ''),
 ('100381-01', 'sun3/tar', '/usr/bin/tar', '755', ''),
 ('100383-06', 'sun3/4.1/rdist', '/usr/ucb/rdist', '4751', 'root.staff'),
 ('100390-01', 'sun3/in.named-xfer', '/usr/etc/in.named-xfer', '755', 'root'),
 ('100399-02', 'sun3/4.1.1/csh', '/usr/bin/csh', '755', ''),
 ('100407-09', 'sun3/4.1.1/acctcms', '/usr/lib/acct/acctcms', '755', 'root.staff'),
 ('100407-09', 'sun3/4.1.1/acctprc2', '/usr/lib/acct/acctprc2', '755', 'root.staff'),
 ('100407-09', 'sun3/4.1.1/ckpacct', '/usr/lib/acct/ckpacct', '755', 'root.staff'),
 ('100407-09', 'sun3/4.1.1/runacct', '/usr/lib/acct/runacct', '755', 'root.staff'),
 ('100407-09', 'sun3/4.1.1/acctcon1', '/usr/lib/acct/acctcon1', '755', 'root.staff'),
 ('100407-09', 'sun3/4.1.1/utmp2wtmp', '/usr/lib/acct/utmp2wtmp', '755', 'root.staff'),
 ('100407-09', 'sun3/4.1.1/acctprc1', '/usr/lib/acct/acctprc1', '755', 'root.staff'),
 ('100407-09', 'sun3/4.1.1/acctcom', '/usr/bin/acctcom', '755', 'root.staff'),
 ('100408-01', 'sun3/libcurses.a', '/usr/5lib/libcurses.a', '', ''),
 ('100408-01', 'sun3/libcurses_p.a', '/usr/5lib/libcurses_p.a', '', ''),
 ('100416-01', 'sun3/tip', '/usr/bin/tip', '4711', 'uucp'),
 ('100421-03', 'sun3/4.1.1/rpc.rexd', '/usr/etc/rpc.rexd', '', ''),
 ('100421-03', 'sun3/4.1.1/on', '/usr/bin/on', '', ''),
 ('100424-01', 'sun3/fsirand', '/usr/etc/fsirand', '755', 'root.staff'),
 ('100425-01', 'sun3/whois', '/usr/ucb/whois', '', ''),
 ('100449-01', 'sun3/ex', '/usr/ucb/ex', '755', ''),
 ('100468-03', 'sun3/4.1.1/rsh', '/usr/ucb/rsh', '4755', ''),
 ('100468-03', 'sun3/4.1.1/rcp', '/usr/ucb/rcp', '4755', ''),
 ('100482-06', 'sun3/4.1.1/ypserv', '/usr/etc/ypserv', '755', 'root.staff'),
 ('100482-06', 'sun3/4.1.1/ypxfrd', '/usr/etc/ypxfrd', '755', 'root.staff'),
 ('100482-06', 'sun3/4.1.1/portmap', '/usr/etc/portmap', '755', 'root.staff'),
 ('100482-06', 'sun3/4.1.1/securenets', '/var/yp/securenets', '644', 'root.staff'),
 ('100549-01', 'sun3/lex', '/usr/bin/lex', '755', ''),
 ('100556-02', 'sun3/4.1.1/cpio', '/usr/bin/cpio', '755', 'root.staff'),
 ('100593-03', 'sun3/4.1.1/dump', '/usr/etc/dump', '6755', 'root.tty'),
 ('100600-01', 'sun3/4.1.1/fsck', '/usr/etc/fsck', '755', 'root.staff'),
 ('100619-01', 'sun3/4.1.1/make.4.1.1.3', '/usr/bin/make', '755', 'root'),
 ('100620-01', 'sun3/4.1.1/iropt.4113', '/usr/lib/iropt', '555', 'root'),
 ('100630-02', 'sun3/login', '/usr/bin/login', '4755', 'root.staff'),
 ('100630-02', 'sun3/su', '/usr/bin/su', '4755', 'root.staff'),
 ('100630-02', 'sun3/su.5bin', '/usr/5bin/su', '4755', 'root.staff'),
 ('100634-01', 'sun3/libnbio.a', '/usr/lib/libnbio.a', '', ''),
 ('100650-02', 'sun3/ipcs', '/usr/bin/ipcs', '2755', 'root.kmem'),
 ('100651-01', 'sun3/4.1.1/cron', '/usr/etc/cron', '', ''),
 ('100654-01', 'sun3/4.1.1/installtxt', '/usr/etc/installtxt', '755', 'root.staff'),
 ('100672-01', 'sun3/aiolib.a', '/usr/lib/aiolib.a', '644', 'root.staff'),
 ('100909-03', 'sun3/4.1.1/syslogd', '/usr/etc/syslogd', '755', 'root.staff'),
 ('101072-02', 'sun3/tar', '/usr/bin/tar', '755', 'root.staff'),
 ('101080-01', 'sun3/expreserve', '/usr/lib/expreserve', '4755', 'root.staff'),
 ('101480-01', 'sun3/4.1.1/in.talkd', '/usr/etc/in.talkd', '755', 'root.staff'),
 ('101481-01', 'sun3/4.1.1/shutdown', '/usr/etc/shutdown', '4754', 'root.operator'),
 ('101482-01', 'sun3/4.1.1/write', '/usr/bin/write', '2755', 'root.tty'),
 ('101783-02', '4.1.1/sun3/ldd', '/usr/bin/ldd', '755', ''),
 ('101783-02', '4.1.1/sun3/ldconfig', '/usr/etc/ldconfig', '755', ''),
 ('101817-01', 'sun3/4.1.1/rpc.lockd', '/usr/etc/rpc.lockd', '755', ''),
]
RANLIB = ['/usr/openwin/lib/libolgx.a', '/usr/xpg2lib/libxpg.a', '/usr/xpg2lib/libxpg_p.a',
          '/usr/5lib/libcurses.a', '/usr/5lib/libcurses_p.a', '/usr/lib/libnbio.a', '/usr/lib/aiolib.a']
RANLIB_T = ['/usr/openwin/lib/libxview.a', '/usr/openwin/lib/libxview.sa.3.0']

# kernel objects, into /sys/sun3/OBJ
KO = [('100126-05', 'sun3/locore.o'), ('100126-05', 'sun3/uipc_mbuf.o'),
      ('100192-02', '4.1.1/sun3/windt.o'),
      ('100254-02', 'sun3/4.1.1/tty_ttcompat.o'),
      ('100303-02', 'sun3/tcp_input.o'),
      ('100338-05', 'sun3/4.1.1/spec_vnodeops.o'),
      ('100359-08', 'sun3/4.1.1/str_io.o'), ('100359-08', 'sun3/4.1.1/str_syscalls.o'),
      ('100361-03', 'sun3/4.1.1/if_ether.o'),
      ('100384-01', 'sun3/rsc.o'),
      ('100412-02', 'sun3/4.1.1/in_pcb.o'),
      ('100458-03', '4.1.1/sun3/kern_sig.o')]
KO += [('100513-04', 'sun3/4.1.1/%s.o' % n) for n in 'cons mcp_async mti tty_ldterm tty_pty zs_async'.split()]
KO += [('100567-04', 'sun3/ip_icmp.o')]
KO += [('100622-01', 'sun3/%s.o' % n) for n in 'ufs_bmap ufs_dir ufs_inode ufs_subr ufs_vfsops ufs_vnodeops'.split()]
KO += [('101817-01', 'sun3/4.1.1/%s.o' % n) for n in 'kern_descrip klm_lockmgr ufs_lockf'.split()]
KO += [('102231-01', 'sun3/4.1.1/%s.o' % n) for n in
       'nfs_client nfs_common nfs_dump nfs_export nfs_server nfs_subr nfs_vfsops nfs_vnodeops nfs_xdr seg_vn svc_kudp'.split()]
KH = [('102231-01', 'sun3/4.1.1/%s' % n) for n in 'nfs.h nfs_clnt.h rnode.h export.h'.split()]

Y2K = set('/usr/kvm/w /usr/kvm/eeprom /usr/5bin/touch /usr/5bin/date /usr/bin/date /usr/bin/at /usr/bin/atq /usr/bin/bar /usr/bin/passwd'.split())
for p, s, d, m, o in U:
    b = os.path.basename(d); assert d not in Y2K and not b.startswith(('libc.', 'libc_')) and 'tmac' not in d, d

Y2KF = '/usr/kvm/w /usr/kvm/eeprom /usr/5bin/touch /usr/5bin/date /usr/bin/date /usr/bin/at /usr/bin/atq /usr/bin/bar /usr/bin/passwd /usr/share/man/man8/eeprom.8s /usr/lib/tmac/tmac.an /usr/lib/tmac/tmac.e /usr/lib/tmac/tmac.os /usr/lib/tmac/tmac.s /usr/lib/libc.a /usr/lib/libc_p.a /usr/5lib/libc.a /usr/5lib/libc_p.a /usr/lib/libc.so.0.15.3 /usr/lib/libc.sa.0.15.3 /usr/5lib/libc.so.1.15.3 /usr/5lib/libc.sa.1.15.3 /usr/lib/shlib.etc/libc_pic.a /usr/lib/shlib.etc/libcs5_pic.a'
PATCHES = sorted(set([u[0] for u in U] + [k[0] for k in KO] + ['100103-12', '101783-02']))

def q(s):
    return "'" + s + "'"

user = ['#!/sbin/sh',
        '# install.sh: the user-level half of the SunOS 4.1.1 patches docs/sunos-patches.md',
        '# lists as missing on a 4.1.1_U1 + y2kpatch-04 system.  Run as root in single',
        '# user, with /sbin/sh:  /sbin/sh /home/kit/install.sh',
        '# Each file it replaces is kept beside itself as <file>.pre-<patch>, mode 400.',
        '# The y2kpatch-04 files (date, w, at, atq, bar, passwd, eeprom, touch, tmac, libc)',
        '# are not touched.',
        'K=/home/kit/p',
        'fails=0',
        'put() {',
        '  id=$1; src=$K/$1/$2; dst=$3; mode=$4; own=$5',
        '  if [ ! -f "$src" ]; then echo "FAIL $id: no $src"; fails=`expr $fails + 1`; return; fi',
        '  if [ -f "$dst" ]; then',
        '    echo "was $id $dst `ls -lg $dst`"',
        '    if [ ! -f "$dst.pre-$id" ]; then',
        '      cp -p "$dst" "$dst.pre-$id" || { echo "FAIL $id: backup $dst"; fails=`expr $fails + 1`; return; }',
        '      chmod 400 "$dst.pre-$id"',
        '    fi',
        '    cat "$src" > "$dst" || { echo "FAIL $id: write $dst"; fails=`expr $fails + 1`; return; }',
        '  else',
        '    cp "$src" "$dst" || { echo "FAIL $id: copy $dst"; fails=`expr $fails + 1`; return; }',
        '  fi',
        '  [ -n "$mode" ] && chmod $mode "$dst"',
        '  [ -n "$own" ] && chown $own "$dst"',
        '  cmp -s "$src" "$dst" || { echo "FAIL $id: $dst differs"; fails=`expr $fails + 1`; return; }',
        '  echo "ok  $id $dst `ls -lg $dst`"',
        '}',
        'echo "install.sh start `date`"',
        'sum ' + Y2KF + ' > /home/kit/y2k.before',
        'mkdir -p $K',
        'for t in /home/kit/patches/*.tar; do',
        '  id=`basename $t .tar`; mkdir -p $K/$id; (cd $K/$id && tar xf $t) || echo "FAIL untar $id"',
        'done']
for p, s, d, m, o in U:
    if p == '101783-02':
        continue
    line = 'put %s %s %s %s %s' % (p, q(member(p, s)), d, q(m), q(o))
    if d.startswith('/var/yp/'):        # only where NIS has been set up
        line = 'if [ -d /var/yp ]; then %s; else echo "ok  %s no /var/yp: %s left out"; fi' % (line, p, d)
    user.append(line)
    if p == '100305-15' and s.endswith('cancel'):
        user += ['# 100305-15: the spool socket moves to /dev/lpd',
                 'rm -f /dev/printer /var/spool/lpd.lock',
                 '[ -d /dev/lpd ] || mkdir /dev/lpd',
                 'chown root.daemon /dev/lpd; chmod 710 /dev/lpd',
                 'ln -s /dev/lpd/printer /dev/printer']
    if p == '100408-01' and s.endswith('libcurses_p.a'):
        user += ['# 100408-01: libtermcap and libtermlib are links to libcurses',
                 'for n in termcap termlib; do',
                 '  [ -f /usr/5lib/lib$n.a.pre-100408-01 ] || mv /usr/5lib/lib$n.a /usr/5lib/lib$n.a.pre-100408-01',
                 '  [ -f /usr/5lib/lib${n}_p.a.pre-100408-01 ] || mv /usr/5lib/lib${n}_p.a /usr/5lib/lib${n}_p.a.pre-100408-01',
                 '  rm -f /usr/5lib/lib$n.a /usr/5lib/lib${n}_p.a',
                 '  ln /usr/5lib/libcurses.a /usr/5lib/lib$n.a',
                 '  ln /usr/5lib/libcurses_p.a /usr/5lib/lib${n}_p.a',
                 'done']
user += ['ranlib ' + ' '.join(RANLIB),
         'ranlib -t ' + ' '.join(RANLIB_T),
         '# 100185-01: /etc/rc.local builds /etc/motd through /tmp/t1, which a symbolic link can redirect',
         'if grep -s "/tmp/t1" /etc/rc.local; then',
         '  [ -f /etc/rc.local.pre-100185-01 ] || cp -p /etc/rc.local /etc/rc.local.pre-100185-01',
         "  sed -e 's;/tmp/t1;/etc/motd.t1;g' -e 's;chmod 666 /etc/motd;chmod 644 /etc/motd;' /etc/rc.local.pre-100185-01 > /etc/rc.local",
         '  echo "ok  100185-01 /etc/rc.local"; grep -n motd /etc/rc.local',
         'else echo "ok  100185-01 nothing to change in /etc/rc.local"; fi',
         '# 101783-02: ldd, ldconfig, then ld.so swapped in one rename (every dynamic program maps it)',
         'put 101783-02 %s /usr/bin/ldd 755 ""' % q(member('101783-02', '4.1.1/sun3/ldd')),
         'put 101783-02 %s /usr/etc/ldconfig 755 ""' % q(member('101783-02', '4.1.1/sun3/ldconfig')),
         'echo "was 101783-02 /usr/lib/ld.so `ls -lg /usr/lib/ld.so`"',
         'cp $K/101783-02/%s /usr/lib/ld.so+ && chmod 555 /usr/lib/ld.so+ && ' % member('101783-02', '4.1.1/sun3/ld.so') +
         '{ [ -f /usr/lib/ld.so.pre-101783-02 ] || ln /usr/lib/ld.so /usr/lib/ld.so.pre-101783-02; } && ' +
         'mv /usr/lib/ld.so+ /usr/lib/ld.so && echo "ok  101783-02 /usr/lib/ld.so `ls -lg /usr/lib/ld.so`" || ' +
         '{ echo "FAIL 101783-02 ld.so"; fails=`expr $fails + 1`; }',
         '/usr/etc/ldconfig',
         'echo "test: `/usr/bin/date`"; /usr/bin/ls -l /usr/lib/ld.so* > /dev/null && echo "test: ls runs"',
         '# 100103-12: tighten file permissions (its list has none of the y2kpatch-04 files)',
         'cp $K/100103-12/%s /home/kit/4.1secure.sh && chmod 710 /home/kit/4.1secure.sh' % member('100103-12', '4.1secure.sh'),
         '/sbin/sh /home/kit/4.1secure.sh || echo "FAIL 100103-12 (exit $?)"',
         'sum ' + Y2KF + ' > /home/kit/y2k.after',
         'cmp -s /home/kit/y2k.before /home/kit/y2k.after && echo "ok  y2kpatch-04 files unchanged" || { echo "FAIL y2kpatch-04 files changed:"; diff /home/kit/y2k.before /home/kit/y2k.after; fails=`expr $fails + 1`; }',
         'sync; sync',
         'echo "install.sh done `date`: $fails failures"']

kern = ['#!/sbin/sh',
        '# kernel.sh: the kernel half -- objects into /sys/sun3/OBJ, the NFS headers, then',
        '# a GENERIC kernel built as /sys/sun3/GENERIC/vmunix and copied to /vmunix.new.',
        '# Each object it replaces is kept as <object>.pre-<patch>.',
        'K=/home/kit/p; O=/usr/kvm/sys/sun3/OBJ',
        'fails=0',
        'kput() {',
        '  id=$1; src=$K/$1/$2; dst=$3',
        '  if [ ! -f "$src" ]; then echo "FAIL $id: no $src"; fails=`expr $fails + 1`; return; fi',
        '  if [ -f "$dst" ] && [ ! -f "$dst.pre-$id" ]; then mv "$dst" "$dst.pre-$id"; fi',
        '  rm -f "$dst"; cp "$src" "$dst" && chmod 444 "$dst" && cmp -s "$src" "$dst" &&',
        '    echo "ok  $id $dst" || { echo "FAIL $id: $dst"; fails=`expr $fails + 1`; }',
        '}',
        'echo "kernel.sh start `date`"']
for p, s in KO:
    kern.append('kput %s %s $O/%s' % (p, q(member(p, s)), os.path.basename(s)))
for p, s in KH:
    for d in ('/usr/kvm/sys/nfs', '/usr/include/nfs'):
        kern.append('kput %s %s %s/%s' % (p, q(member(p, s)), d, os.path.basename(s)))
kern += ['[ $fails = 0 ] || { echo "kernel.sh: $fails failures, not building"; exit 1; }',
         'cd /usr/kvm/sys/sun3/conf || exit 1',
         '/usr/etc/config GENERIC || { echo "FAIL config"; exit 1; }',
         'cd ../GENERIC || exit 1',
         'echo "make start `date`"',
         'make > /home/kit/make.log 2>&1; st=$?',
         'tail -15 /home/kit/make.log',
         'echo "make done `date`: exit $st"',
         '[ $st = 0 ] && [ -f vmunix ] || { echo "FAIL make"; exit 1; }',
         'cp vmunix /vmunix.new && ls -l /vmunix /vmunix.new',
         'sync; sync',
         'echo "kernel.sh done `date`"']

if os.path.isdir(KIT): shutil.rmtree(KIT)
os.makedirs(os.path.join(KIT, 'patches'))
for p in PATCHES:
    shutil.copy(D + p + '.tar', os.path.join(KIT, 'patches'))
    shutil.copy(D + p + '.README', os.path.join(KIT, 'patches'))
open(os.path.join(KIT, 'install.sh'), 'wb').write(('\n'.join(user) + '\n').encode())
open(os.path.join(KIT, 'kernel.sh'), 'wb').write(('\n'.join(kern) + '\n').encode())

# one tar of kit/, extracted on the Sun in /home
def owned(ti):
    ti.uid = ti.gid = 0; ti.uname = ti.gname = ''
    ti.mode = 0o755 if ti.isdir() or ti.name.endswith('.sh') else 0o644
    return ti
with tarfile.open(os.path.join(OUT, '01-kit.tar'), 'w', format=tarfile.USTAR_FORMAT) as t:
    t.add(KIT, 'kit', filter=owned)
print(len(PATCHES), 'patches;', len(U), 'files;', len(KO), 'objects;', len(KH), 'headers')
