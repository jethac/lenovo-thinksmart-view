// ssbo-probe: run one compute shader on a known SSBO pattern and dump the
// output buffer, to see byte by byte what a (possibly hand-assembled, via
// IR3_SHADER_OVERRIDE_PATH) load/store sequence does.
//
//   ssbo-probe SHADER.comp [GROUPS]
//
// binding 0: input, 256 bytes, little-endian u16 element i = 0xA000 + i
// binding 1: output, 256 bytes, pre-filled with 0xEE
// Prints the output as u16 words, 16 per line, "...." for untouched 0xEEEE.
#include "glctx.h"
#include <stdint.h>

int main(int argc, char **argv)
{
    if (argc < 2) die("usage: ssbo-probe SHADER.comp [GROUPS]");
    int groups = argc > 2 ? atoi(argv[2]) : 1;
    gl_init();
    GLuint p = make_prog(read_file(argv[1]), 0);
    if (!p) return 1;
    uint16_t in[128], out[128];
    for (int i = 0; i < 128; i++) in[i] = 0xA000 + i;
    memset(out, 0xEE, sizeof out);
    GLuint bi = make_ssbo(0, sizeof in, in);
    GLuint bo = make_ssbo(1, sizeof out, out);
    p_glUseProgram(p);
    p_glDispatchCompute(groups, 1, 1);
    p_glMemoryBarrier(GL_ALL_BARRIER_BITS);
    p_glFinish();
    GLenum e = p_glGetError();
    if (e) fprintf(stderr, "GL error 0x%x\n", e);
    read_ssbo(bo, sizeof out, out);
    for (int i = 0; i < 128; i++) {
        if (out[i] == 0xEEEE) printf(" ....");
        else printf(" %04x", out[i]);
        if (i % 16 == 15) printf("   [%3d..%3d]\n", i - 15, i);
    }
    (void)bi;
    return 0;
}
