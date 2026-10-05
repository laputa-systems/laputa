use pm.proof
use pm.util as pm_util

# The proof runs headless in the build container with no /dev/dri. It renders
# through EGL's surfaceless platform, which falls back to softpipe: compiling
# GLSL shaders, drawing into a renderbuffer, and reading the pixels back
# exercises the vendored GLSL parser and NIR tables, the GL API dispatch, and
# the gallium driver. A GBM device on /dev/null cannot allocate buffers (that
# needs a DRM node), but creating it and initializing EGL on it proves libgbm
# loads the dri_gbm backend from the GBM backends path and reaches libgallium.
const program_source = """#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdio.h>

static const char *vs_src =
    "attribute vec2 pos;\\n"
    "void main() { gl_Position = vec4(pos, 0.0, 1.0); }\\n";
static const char *fs_src =
    "precision mediump float;\\n"
    "uniform vec4 color;\\n"
    "void main() { gl_FragColor = color; }\\n";

static GLuint compile(GLenum type, const char *src)
{
    GLuint shader = glCreateShader(type);
    GLint ok = 0;
    glShaderSource(shader, 1, &src, NULL);
    glCompileShader(shader);
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "shader compile failed: %s\\n", log);
        return 0;
    }
    return shader;
}

int main(void)
{
    PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!get_platform_display) {
        fprintf(stderr, "no eglGetPlatformDisplayEXT\\n");
        return 1;
    }

    struct gbm_device *gbm = gbm_create_device(open("/dev/null", O_RDWR | O_CLOEXEC));
    if (!gbm) {
        fprintf(stderr, "gbm_create_device failed\\n");
        return 2;
    }
    EGLDisplay gbm_dpy = get_platform_display(EGL_PLATFORM_GBM_KHR, gbm, NULL);
    if (gbm_dpy == EGL_NO_DISPLAY || !eglInitialize(gbm_dpy, NULL, NULL)) {
        fprintf(stderr, "EGL on GBM failed: 0x%x\\n", eglGetError());
        return 3;
    }
    printf("gbm backend=%s\\n", gbm_device_get_backend_name(gbm));
    eglTerminate(gbm_dpy);

    EGLDisplay dpy = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    EGLint major = 0, minor = 0;
    if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, &major, &minor)) {
        fprintf(stderr, "eglInitialize failed: 0x%x\\n", eglGetError());
        return 4;
    }
    eglBindAPI(EGL_OPENGL_ES_API);
    static const EGLint ctx_attribs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ctx_attribs);
    if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
        fprintf(stderr, "context failed: 0x%x\\n", eglGetError());
        return 5;
    }
    printf("EGL %d.%d\\nGL_RENDERER=%s\\nGL_VERSION=%s\\n", major, minor, glGetString(GL_RENDERER),
           glGetString(GL_VERSION));

    GLuint rb, fb;
    glGenRenderbuffers(1, &rb);
    glBindRenderbuffer(GL_RENDERBUFFER, rb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA4, 8, 8);
    glGenFramebuffers(1, &fb);
    glBindFramebuffer(GL_FRAMEBUFFER, fb);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "framebuffer incomplete\\n");
        return 6;
    }

    GLuint vs = compile(GL_VERTEX_SHADER, vs_src);
    GLuint fs = compile(GL_FRAGMENT_SHADER, fs_src);
    if (!vs || !fs)
        return 7;
    GLuint prog = glCreateProgram();
    GLint linked = 0;
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glBindAttribLocation(prog, 0, "pos");
    glLinkProgram(prog);
    glGetProgramiv(prog, GL_LINK_STATUS, &linked);
    if (!linked) {
        fprintf(stderr, "program link failed\\n");
        return 8;
    }

    /* Clear to blue, then draw red over the left half (x < 0 in NDC). */
    static const GLfloat strip[] = {-1.0f, -1.0f, 0.0f, -1.0f, -1.0f, 1.0f, 0.0f, 1.0f};
    unsigned char px[8 * 8 * 4];
    glViewport(0, 0, 8, 8);
    glClearColor(0.0f, 0.0f, 1.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(prog);
    glUniform4f(glGetUniformLocation(prog, "color"), 1.0f, 0.0f, 0.0f, 1.0f);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, strip);
    glEnableVertexAttribArray(0);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glReadPixels(0, 0, 8, 8, GL_RGBA, GL_UNSIGNED_BYTE, px);
    const unsigned char *left = &px[(4 * 8 + 1) * 4];
    const unsigned char *right = &px[(4 * 8 + 6) * 4];
    if (glGetError() != GL_NO_ERROR || left[0] != 255 || left[2] != 0 || right[0] != 0 || right[2] != 255) {
        fprintf(stderr, "unexpected pixels: left=%u,%u,%u right=%u,%u,%u\\n", left[0], left[1], left[2], right[0],
                right[1], right[2]);
        return 9;
    }
    eglTerminate(dpy);
    puts("rendered");
    return 0;
}
"""

# The gallium library is named for the Mesa version.
proc gallium_library(root: Path) -> Result[Path] {
  let found = [entry.path for entry in fs.children(fp"{root}/usr/lib") if entry.name.starts_with("libgallium-") and entry.name.ends_with(".so")]
  proof.ensure(found.len() == 1, "proof-mesa", f"expected one libgallium, found {found.len()}")
  found[0].relative_to(root)
}

# Mesa is built without LLVM and links libc++ statically, so the runtime
# closure carries neither libLLVM nor a C++ library.
proc check_runtime_needs(root: Path, rels: List[Path]) {
  for rel in rels {
    for needed in elf.inspect(fp"{root}/{rel}")?.needed {
      proof.ensure(! needed.starts_with("libLLVM") and ! needed.starts_with("libc++"), "proof-mesa", f"{rel} links {needed}")
    }
  }
}

proc main(root: Path = /rootfs) [fs, process, env, error] {
  let libraries = [
    p"usr/lib/libEGL.so.1.0.0",
    p"usr/lib/libGLESv2.so.2.0.0",
    p"usr/lib/libgbm.so.1.0.0",
    gallium_library(root)?,
    p"usr/lib/gbm/dri_gbm.so",
  ]

  for rel in libraries {
    proof.target_elf(root, rel, "mesa")
  }

  check_runtime_needs(root, libraries)

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "mesa ok: cross-built "${pm_util.target_arch()?}
    return
  }

  let cc = process.which("cc")?
  let tmp = fp"{root}/var/tmp/proof-mesa"
  tmp.remove(missing_ok: true)
  tmp.mkdir()
  defer tmp.remove(missing_ok: true)
  let source = fp"{tmp}/proof-mesa.c"
  let binary = fp"{tmp}/proof-mesa"
  source.write(program_source)
  run $cc $source f"-I{root}/usr/include" f"-L{root}/usr/lib" "-lEGL" "-lGLESv2" "-lgbm" "-o" $binary

  env ({
    LD_LIBRARY_PATH: fp"{root}/usr/lib".display(),
    GBM_BACKENDS_PATH: fp"{root}/usr/lib/gbm".display(),
  }) {
    let out = run.text $binary
    proof.ensure("GL_RENDERER=softpipe" in out, "proof-mesa", f"unexpected renderer: {out}")
    proof.ensure("OpenGL ES 3.1 Mesa" in out, "proof-mesa", f"unexpected GL version: {out}")
    proof.ensure("rendered" in out, "proof-mesa", f"render check failed: {out}")
    print f"mesa ok: {out.trim().split("\n").join("; ")}"
  }?
}

main(@args)
