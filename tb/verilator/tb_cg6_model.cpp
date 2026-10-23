// tb_cg6's +lockstep: tools/cg6model's board run beside the RTL, through
// DPI, so that a difference is found at the command that makes it rather than
// at the end of a trace.  The model is compiled here, as C++.
#include <cstdint>
#include <cstring>
#include <climits>

extern "C" {
#include "../../tools/cg6model/cg6model.c"

static struct cg6 M;

void cg6m_reset(void) { cg6_reset(&M); }
void cg6m_pixel_set(int p, int v) { M.fb[p & (CG6_FBSIZE - 1)] = (uint8_t)v; }
int  cg6m_pixel(int p) { return M.fb[p & (CG6_FBSIZE - 1)]; }
void cg6m_write(int off, int size, int v) { cg6_write(&M, (uint32_t)off, size, (uint32_t)v); }
int  cg6m_read(int off, int size) { return (int)cg6_read(&M, (uint32_t)off, size); }
}
