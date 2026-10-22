// OpenGL for the visualisers, through libepoxy, which GTK itself uses to reach GL and
// GLES alike.
//
// Epoxy's entry points are global function pointers behind macros. Swift sees neither
// the macros nor, under strict concurrency, the mutable pointers, so each call the
// renderer makes is a plain function here.

#include <epoxy/gl.h>

static inline GLuint cgl_create_shader(GLenum type) { return glCreateShader(type); }
static inline void cgl_shader_source(GLuint shader, const char *source) { glShaderSource(shader, 1, &source, NULL); }
static inline void cgl_compile_shader(GLuint shader) { glCompileShader(shader); }
static inline GLint cgl_shader_status(GLuint shader) {
    GLint status = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    return status;
}
static inline void cgl_shader_log(GLuint shader, GLsizei size, char *log) { glGetShaderInfoLog(shader, size, NULL, log); }
static inline void cgl_delete_shader(GLuint shader) { glDeleteShader(shader); }

static inline GLuint cgl_create_program(void) { return glCreateProgram(); }
static inline void cgl_attach_shader(GLuint program, GLuint shader) { glAttachShader(program, shader); }
static inline void cgl_link_program(GLuint program) { glLinkProgram(program); }
static inline GLint cgl_program_status(GLuint program) {
    GLint status = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &status);
    return status;
}
static inline void cgl_program_log(GLuint program, GLsizei size, char *log) { glGetProgramInfoLog(program, size, NULL, log); }
static inline void cgl_delete_program(GLuint program) { glDeleteProgram(program); }
static inline void cgl_use_program(GLuint program) { glUseProgram(program); }
static inline GLint cgl_uniform_location(GLuint program, const char *name) { return glGetUniformLocation(program, name); }
static inline void cgl_uniform1i(GLint location, GLint value) { glUniform1i(location, value); }
static inline void cgl_uniform1f(GLint location, GLfloat value) { glUniform1f(location, value); }
static inline void cgl_uniform2f(GLint location, GLfloat x, GLfloat y) { glUniform2f(location, x, y); }

static inline GLuint cgl_vertex_array(void) {
    GLuint array = 0;
    glGenVertexArrays(1, &array);
    return array;
}
static inline void cgl_bind_vertex_array(GLuint array) { glBindVertexArray(array); }
static inline void cgl_delete_vertex_array(GLuint array) { glDeleteVertexArrays(1, &array); }

static inline GLuint cgl_texture(void) {
    GLuint texture = 0;
    glGenTextures(1, &texture);
    return texture;
}
static inline void cgl_delete_texture(GLuint texture) { glDeleteTextures(1, &texture); }
static inline void cgl_active_texture(GLenum unit) { glActiveTexture(unit); }
static inline void cgl_bind_texture(GLuint texture) { glBindTexture(GL_TEXTURE_2D, texture); }
static inline void cgl_texture_parameter(GLenum name, GLint value) { glTexParameteri(GL_TEXTURE_2D, name, value); }
static inline void cgl_texture_image(GLint internalFormat, GLsizei width, GLsizei height, GLenum format, GLenum type, const void *pixels) {
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, internalFormat, width, height, 0, format, type, pixels);
}
static inline void cgl_texture_update(GLsizei width, GLsizei height, GLenum format, GLenum type, const void *pixels) {
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, format, type, pixels);
}

static inline void cgl_viewport_size(GLint *width, GLint *height) {
    GLint viewport[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_VIEWPORT, viewport);
    *width = viewport[2];
    *height = viewport[3];
}
static inline void cgl_viewport(GLint width, GLint height) { glViewport(0, 0, width, height); }
static inline void cgl_clear(void) {
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
}
static inline void cgl_draw_triangle(void) {
    glDisable(GL_BLEND);
    glDrawArrays(GL_TRIANGLES, 0, 3);
}
