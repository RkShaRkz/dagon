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

module dagon.graphics.materials.shadeless;

import std.stdio;
import std.math;
import std.conv;

import dlib.core.memory;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.image.color;
import dlib.image.unmanaged;

import derelict.opengl;

import dagon.core.ownership;
import dagon.graphics.rc;
import dagon.graphics.material;
import dagon.graphics.materials.generic;

/*
 * Backend for shadeless material (e.g., only textured or filled with solid color)
 */

class ShadelessBackend: GLSLMaterialBackend
{
    private string vsText = "
        #version 330 core

        layout (location = 0) in vec3 va_Vertex;
        layout (location = 2) in vec2 va_Texcoord;

        out vec3 eyePosition;
        out vec2 texCoord;

        uniform mat4 modelViewMatrix;
        uniform mat4 projectionMatrix;

        uniform mat4 invViewMatrix;

        void main()
        {
            vec4 pos = modelViewMatrix * vec4(va_Vertex, 1.0);
            eyePosition = pos.xyz;

            texCoord = va_Texcoord;
            gl_Position = projectionMatrix * pos;
        }
    ";

    private string fsText = "
        #version 330 core

        uniform sampler2D diffuseTexture;
        uniform float alpha;
        uniform float energy;

        in vec3 eyePosition;
        in vec2 texCoord;

        layout(location = 0) out vec4 frag_color;
        layout(location = 2) out vec4 frag_position;
        layout(location = 4) out vec4 frag_velocity;
        layout(location = 5) out vec4 frag_luma;

        float luminance(vec3 color)
        {
            return (
                color.x * 0.27 +
                color.y * 0.67 +
                color.z * 0.06
            );
        }

        vec3 toLinear(vec3 v)
        {
            return pow(v, vec3(2.2));
        }

        void main()
        {
            vec4 col = texture(diffuseTexture, texCoord);
            frag_color = vec4(toLinear(col.rgb) * energy, col.a * alpha);
            frag_luma = vec4(energy*luminance(col.rgb), 0.0, 0.0, 1.0);
            frag_velocity = vec4(0.0, 0.0, 0.0, 1.0);
            frag_position = vec4(eyePosition, 0.0);
        }
    ";

    override string vertexShaderSrc() {return vsText;}
    override string fragmentShaderSrc() {return fsText;}

    GLint modelViewMatrixLoc;
    GLint projectionMatrixLoc;

    GLint diffuseTextureLoc;
    GLint alphaLoc;
    GLint energyLoc;

    this(Owner o)
    {
        super(o);

        modelViewMatrixLoc = glGetUniformLocation(shaderProgram, "modelViewMatrix");
        projectionMatrixLoc = glGetUniformLocation(shaderProgram, "projectionMatrix");

        diffuseTextureLoc = glGetUniformLocation(shaderProgram, "diffuseTexture");
        alphaLoc = glGetUniformLocation(shaderProgram, "alpha");
        energyLoc = glGetUniformLocation(shaderProgram, "energy");
    }

    final void setModelViewMatrix(Matrix4x4f modelViewMatrix){
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, modelViewMatrix.arrayof.ptr);
    }

    override void bind(GenericMaterial mat, RenderingContext* rc)
    {
        auto idiffuse = "diffuse" in mat.inputs;
        auto ienergy = "energy" in mat.inputs;
        auto itransparency = "transparency" in mat.inputs;

        float energy = ienergy.asFloat;

        glUseProgram(shaderProgram);

        // Matrices
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, rc.modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(projectionMatrixLoc, 1, GL_FALSE, rc.projectionMatrix.arrayof.ptr);

        // Texture 0 - diffuse texture
        Color4f color = Color4f(idiffuse.asVector4f);
        float alpha = 1.0f;
        if (idiffuse.texture is null)
        {
            idiffuse.texture = makeOnePixelTexture(mat, color);
        }
        if (itransparency)
        {
            alpha = itransparency.asFloat;
        }
        glActiveTexture(GL_TEXTURE0);
        idiffuse.texture.bind();
        glUniform1i(diffuseTextureLoc, 0);
        glUniform1f(alphaLoc, alpha);
        glUniform1f(energyLoc, energy);
    }

    override void unbind(GenericMaterial mat, RenderingContext* rc)
    {
        auto idiffuse = "diffuse" in mat.inputs;

        glActiveTexture(GL_TEXTURE0);
        idiffuse.texture.unbind();

        glUseProgram(0);
    }
}
