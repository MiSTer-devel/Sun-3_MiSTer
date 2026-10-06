# Disk benchmark for the Sun-3 (docs/design-plan.md, Phase 3 step 5).
# Run on SunOS as root, with bash (its time builtin):
#     bash dbench.sh > /dev/ttya 2>&1
# ttya is /dev/ttyS1 on the MiSTer.  Writes /home/z and /home/t, and
# removes them.
echo dbench start
date
echo raw read 10 MB as 64 KB reads
time dd if=/dev/rsd0g of=/dev/null bs=64k count=160
echo raw read 256 KB as 512 B reads
time dd if=/dev/rsd0g of=/dev/null bs=512 count=512
echo bzero 10 MB
time dd if=/dev/zero of=/dev/null bs=64k count=160
echo 300 forks of expr
time sh -c "i=0; while [ \$i -lt 300 ]; do i=\`expr \$i + 1\`; done"
echo file write 10 MB
time sh -c "dd if=/dev/zero of=/home/z bs=64k count=160; sync"
rm -f /home/z
sync
mkdir /home/t
echo tar copy of /usr/include
time sh -c "cd /usr; tar cf - include | (cd /home/t; tar xf -); sync"
echo rm of the copy
time sh -c "rm -rf /home/t; sync"
date
echo bench done
