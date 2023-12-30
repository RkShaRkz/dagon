/*
Copyright (c) 2017-2018 Timur Gafarov

Boost Software License - Version 1.0 - August 17th, 2003
Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/

module dagon.graphics.postproc;

import std.stdio;
import std.conv;

import dlib.math.vector;

import derelict.opengl;

import dagon.core.ownership;
import dagon.graphics.rc;
import dagon.graphics.framebuffer;

class PostFilter: Owner
{
    bool enabled = true;
    Framebuffer inputBuffer;
    Framebuffer outputBuffer;

    GLenum shaderVert;
    GLenum shaderFrag;
    GLenum shaderProgram;

    GLint modelViewMatrixLoc;
    GLint prevModelViewProjMatrixLoc;
    GLint projectionMatrixLoc;
    GLint fbColorLoc;
    GLint viewportSizeLoc;
    GLint enabledLoc;

    private string vsText =
    q{
        #version 300 es
        precision highp float;

        uniform mat4 modelViewMatrix;
        uniform mat4 projectionMatrix;

        uniform vec2 viewSize;

        layout (location = 0) in vec2 va_Vertex;
        layout (location = 1) in vec2 va_Texcoord;

        out vec2 texCoord;

        void main()
        {
            texCoord = va_Texcoord;
            gl_Position = projectionMatrix * modelViewMatrix * vec4(va_Vertex * viewSize, 0.0, 1.0);
        }
    };

    private string fsText =
    q{
        #version 300 es
        precision highp float;

        uniform sampler2D fbColor;
        uniform vec2 viewSize;

        in vec2 texCoord;
        out vec4 frag_color;

        void main()
        {
            vec4 t = texture(fbColor, texCoord);
            frag_color = t;
            frag_color.a = 1.0;
        }
    };

    string vertexShader() {return vsText;}
    string fragmentShader() {return fsText;}

    this(Framebuffer inputBuffer, Framebuffer outputBuffer, Owner o)
    {
        super(o);

        this.inputBuffer = inputBuffer;
        this.outputBuffer = outputBuffer;

        const(char*)pvs = vertexShader().ptr;
        const(char*)pfs = fragmentShader().ptr;

        char[1000] infobuffer = 0;
        int infobufferlen = 0;

        shaderVert = glCreateShader(GL_VERTEX_SHADER);
        glShaderSource(shaderVert, 1, &pvs, null);
        glCompileShader(shaderVert);
        GLint success = 0;
        glGetShaderiv(shaderVert, GL_COMPILE_STATUS, &success);
        if (!success)
        {
            GLint logSize = 0;
            glGetShaderiv(shaderVert, GL_INFO_LOG_LENGTH, &logSize);
            glGetShaderInfoLog(shaderVert, 999, &logSize, infobuffer.ptr);
            writeln("vertex shader error (",__FILE__,":",__LINE__,"):");
            writeln(infobuffer[0..logSize]);
        }

        shaderFrag = glCreateShader(GL_FRAGMENT_SHADER);
        glShaderSource(shaderFrag, 1, &pfs, null);
        glCompileShader(shaderFrag);
        success = 0;
        glGetShaderiv(shaderFrag, GL_COMPILE_STATUS, &success);
        if (!success)
        {
            GLint logSize = 0;
            glGetShaderiv(shaderFrag, GL_INFO_LOG_LENGTH, &logSize);
            glGetShaderInfoLog(shaderFrag, 999, &logSize, infobuffer.ptr);
            writeln("fragment shader error (",typeid(this),"):");
            writeln(infobuffer[0..logSize]);
        }

        shaderProgram = glCreateProgram();
        glAttachShader(shaderProgram, shaderVert);
        glAttachShader(shaderProgram, shaderFrag);
        glLinkProgram(shaderProgram);

        modelViewMatrixLoc = glGetUniformLocation(shaderProgram, "modelViewMatrix");
        prevModelViewProjMatrixLoc = glGetUniformLocation(shaderProgram, "prevModelViewProjMatrix");
        projectionMatrixLoc = glGetUniformLocation(shaderProgram, "projectionMatrix");

        viewportSizeLoc = glGetUniformLocation(shaderProgram, "viewSize");
        fbColorLoc = glGetUniformLocation(shaderProgram, "fbColor");
        enabledLoc = glGetUniformLocation(shaderProgram, "enabled");
    }

    void bind(RenderingContext* rc)
    {
        glUseProgram(shaderProgram);

        glUniformMatrix4fv(modelViewMatrixLoc, 1, 0, rc.viewMatrix.arrayof.ptr);
        glUniformMatrix4fv(projectionMatrixLoc, 1, 0, rc.projectionMatrix.arrayof.ptr);

        glUniformMatrix4fv(prevModelViewProjMatrixLoc, 1, 0, rc.prevModelViewProjMatrix.arrayof.ptr);

        Vector2f viewportSize;

        if (outputBuffer)
            viewportSize = Vector2f(outputBuffer.width, outputBuffer.height);
        else
            viewportSize = Vector2f(rc.width, rc.height);
        glUniform2fv(viewportSizeLoc, 1, viewportSize.arrayof.ptr);

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, inputBuffer.colorTexture);

        glUniform1i(fbColorLoc, 0);

        glUniform1i(enabledLoc, enabled);
    }

    void unbind(RenderingContext* rc)
    {
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, 0);

        glActiveTexture(GL_TEXTURE0);

        glUseProgram(0);
    }

    void render(RenderingContext* rc)
    {
        bind(rc);
        inputBuffer.render();
        unbind(rc);
    }
}
