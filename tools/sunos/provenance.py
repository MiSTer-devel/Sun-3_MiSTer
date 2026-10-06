#!/usr/bin/env python3
"""Where each file on a SunOS 4.1.1 disk came from: the 4.1.1 sets, U1, a
patch (the Y2K patch included), or none of them (made or edited on the
machine).  Archive the disk's / and /usr first, for example with
rusty-backup's `rb-cli tar IMG@1 / root.tar` and `rb-cli tar IMG@3 / usr.tar`.

    provenance.py ROOT.tar USR.tar [OUTDIR]

writes OUTDIR/provenance.txt (every file not as 4.1.1 shipped it, with its
origin) and provenance.json, and prints the counts.  The sets are read from
build/dist/ (sunos-4.1.1/sun3, sunos-4.1.1U1/tape1, sunos-4.1.1-patches)."""
import glob, hashlib, json, os, subprocess, sys, tarfile

R = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = sys.argv[3] if len(sys.argv) > 3 else '.'


def members(path):
    """(name, sha1, size) for every regular file in a tar, plain or .Z."""
    def scan(tf):
        for m in tf:
            if m.isfile():
                f = tf.extractfile(m)
                d = f.read() if f else b''
                yield m.name, hashlib.sha1(d).hexdigest(), len(d)
    try:
        with tarfile.open(path, 'r:') as tf:
            yield from scan(tf)
        return
    except tarfile.ReadError:
        pass
    p = subprocess.Popen(['zcat', path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        with tarfile.open(fileobj=p.stdout, mode='r|') as tf:
            yield from scan(tf)
    except tarfile.ReadError:
        pass
    p.wait()


def nested(path):
    """A patch tar can hold further tars; read those too."""
    for name, sha, size in members(path):
        yield name, sha, size


src = {}          # sha1 -> list of (source, member)
def add(source, path):
    n = 0
    for name, sha, size in nested(path):
        src.setdefault(sha, []).append((source, name))
        n += 1
    return n

for f in sorted(glob.glob(R + '/build/dist/sunos-4.1.1/sun3/sun3_*.tar.Z')):
    add('4.1.1:' + os.path.basename(f).replace('.tar.Z', ''), f)
for f in sorted(glob.glob(R + '/build/dist/sunos-4.1.1U1/tape1/tapeu1.*')):
    add('U1:' + os.path.basename(f), f)
for f in sorted(glob.glob(R + '/build/dist/sunos-4.1.1-patches/*.tar')):
    add('patch:' + os.path.basename(f)[:-4], f)
print('sources:', len(src), 'distinct contents', file=sys.stderr)

rows = []
for part, tarpath, prefix in (('/', sys.argv[1], '/'), ('/usr', sys.argv[2], '/usr/')):
    for name, sha, size in members(tarpath):
        p = prefix + name.lstrip('./')
        origins = src.get(sha, [])
        kinds = sorted({o[0].split(':')[0] for o in origins})
        if '4.1.1' in kinds:
            cls = 'orig'
        elif 'U1' in kinds:
            cls = 'U1'
        elif any(k == 'patch' for k in kinds):
            ids = sorted({o[0].split(':')[1] for o in origins})
            cls = 'patch ' + ','.join(ids)
        else:
            cls = 'none'
        rows.append((p, size, sha, cls))

json.dump(rows, open(OUT + '/provenance.json', 'w'))
counts = {}
for p, size, sha, cls in rows:
    k = cls.split(' ')[0]
    counts[k] = counts.get(k, 0) + 1
print(counts)
with open(OUT + '/provenance.txt', 'w') as f:
    for p, size, sha, cls in sorted(rows):
        if cls != 'orig':
            f.write('%-12s %9d %s\n' % (cls if len(cls) < 40 else cls[:37] + '...', size, p))
