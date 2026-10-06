/*
 * Memory bandwidth from user space, for the Sun-3 (docs/design-plan.md).
 * On SunOS:  cc -O -o membench membench.c && ./membench
 */
#include <stdio.h>
#include <sys/time.h>
#define N (1024*1024)
long a[N/4], b[N/4];
double now()
{
	struct timeval t;
	gettimeofday(&t, (struct timezone *)0);
	return t.tv_sec + t.tv_usec / 1e6;
}
main()
{
	register long *p, *e, s = 0;
	register int r;
	double t;
	for (p = a, e = a + N/4; p < e; p++) *p = 1;
	for (p = b, e = b + N/4; p < e; p++) *p = 0;
	t = now();
	for (r = 0; r < 4; r++)
		for (p = a, e = a + N/4; p < e; ) { *p++ = r; *p++ = r; *p++ = r; *p++ = r; }
	printf("write 4 MB: %.2f MB/s\n", 4.0 / (now() - t));
	t = now();
	for (r = 0; r < 4; r++)
		for (p = a, e = a + N/4; p < e; ) { s += *p++; s += *p++; s += *p++; s += *p++; }
	printf("read 4 MB: %.2f MB/s\n", 4.0 / (now() - t));
	t = now();
	for (r = 0; r < 1024; r++)
		for (p = a, e = a + 1024; p < e; ) { s += *p++; s += *p++; s += *p++; s += *p++; }
	printf("cached read 4 MB: %.2f MB/s\n", 4.0 / (now() - t));
	t = now();
	for (r = 0; r < 4; r++) bcopy((char *)a, (char *)b, N);
	printf("bcopy 4 MB: %.2f MB/s\n", 4.0 / (now() - t));
	t = now();
	for (r = 0; r < 4; r++) bzero((char *)b, N);
	printf("bzero 4 MB: %.2f MB/s\n", 4.0 / (now() - t));
	printf("(%ld)\n", s);
	exit(0);
}
