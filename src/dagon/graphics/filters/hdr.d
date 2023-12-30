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

module dagon.graphics.filters.hdr;

import derelict.opengl;
import dagon.core.ownership;
import dagon.graphics.postproc;
import dagon.graphics.framebuffer;
import dagon.graphics.texture;
import dagon.graphics.rc;

/*
 * tonemapHable is based on a function by John Hable:
 * http://filmicworlds.com/blog/filmic-tonemapping-operators
 *
 * tonemapACES is based on a function by Krzysztof Narkowicz:
 * https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve
 *
 * LUT function (lookupColor) is based on a code by Matt DesLauriers:
 * https://github.com/mattdesl/glsl-lut
 */

enum Tonemapper
{
    Reinhard = 0,
    Hable = 1,
    ACES = 2
}

class PostFilterHDR: PostFilter
{
    private string vs = "
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
    ";

    private string fs = "
        #version 300 es
        precision highp float;

        uniform sampler2D fbColor;
        uniform sampler2D fbVelocity;
        uniform sampler2D colorTable;
        uniform sampler2D vignette;
        uniform vec2 viewSize;
        uniform float timeStep;

        uniform bool useMotionBlur;
        uniform int motionBlurSamples;
        uniform float shutterFps;

        uniform float exposure;
        uniform int tonemapFunction;

        uniform bool useLUT;
        uniform bool useVignette;

        in vec2 texCoord;

        out vec4 frag_color;

        vec3 hableFunc(vec3 x)
        {
            return ((x * (0.15 * x + 0.1 * 0.5) + 0.2 * 0.02) / (x * (0.15 * x + 0.5) + 0.2 * 0.3)) - 0.02 / 0.3;
        }

        vec3 tonemapHable(vec3 x, float expo)
        {
            const vec3 whitePoint = vec3(11.2);
            vec3 c = x * expo;
            c = hableFunc(c * 2.0) * (1.0 / hableFunc(whitePoint));
            return pow(c, vec3(1.0 / 2.2));
        }

        vec3 tonemapReinhard(vec3 x, float expo)
        {
            vec3 c = x * expo;
            c = c / (c + 1.0);
            return pow(c, vec3(1.0 / 2.2));
        }

        vec3 tonemapACES(vec3 x, float expo)
        {
            float a = 2.51;
            float b = 0.03;
            float c = 2.43;
            float d = 0.59;
            float e = 0.14;
            vec3 res = x * expo * 0.6;
            res = clamp((res*(a*res+b))/(res*(c*res+d)+e), 0.0, 1.0);
            return pow(res, vec3(1.0 / 2.2));
        }

        vec3 lookupColor(sampler2D lookupTable, vec3 textureColor)
        {
            textureColor = clamp(textureColor, 0.0, 1.0);

            float blueColor = textureColor.b * 63.0;

            vec2 quad1;
            quad1.y = floor(floor(blueColor) / 8.0);
            quad1.x = floor(blueColor) - (quad1.y * 8.0);

            vec2 quad2;
            quad2.y = floor(ceil(blueColor) / 8.0);
            quad2.x = ceil(blueColor) - (quad2.y * 8.0);

            vec2 texPos1;
            texPos1.x = (quad1.x * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.r);
            texPos1.y = (quad1.y * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.g);

            vec2 texPos2;
            texPos2.x = (quad2.x * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.r);
            texPos2.y = (quad2.y * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.g);

            vec3 newColor1 = texture(lookupTable, texPos1).rgb;
            vec3 newColor2 = texture(lookupTable, texPos2).rgb;

            vec3 newColor = mix(newColor1, newColor2, fract(blueColor));
            return newColor;
        }

        void main()
        {
            vec3 res = texture(fbColor, texCoord).rgb;

            if (useMotionBlur)
            {
                vec2 blurVec = texture(fbVelocity, texCoord).xy;
                blurVec = blurVec / (timeStep * shutterFps);
                float invSamplesMinusOne = 1.0 / float(motionBlurSamples - 1);
                float usedSamples = 1.0;

                for (float i = 1.0; i < float(motionBlurSamples); i++)
                {
                    vec2 offset = blurVec * (i * invSamplesMinusOne - 0.5);
                    float mask = texture(fbVelocity, texCoord + offset).w;
                    res += texture(fbColor, texCoord + offset).rgb * mask;
                    usedSamples += mask;
                }

                res = res / usedSamples;
            }

            if (tonemapFunction == 2)
                res = tonemapACES(res, exposure);
            else if (tonemapFunction == 1)
                res = tonemapHable(res, exposure);
            else
                res = tonemapReinhard(res, exposure);

            if (useVignette)
                res = mix(res, res * texture(vignette, vec2(texCoord.x, 1.0 - texCoord.y)).rgb, 0.8);

            if (useLUT)
                res = lookupColor(colorTable, res);

            frag_color = vec4(res, 1.0);
        }
    ";

    override string vertexShader()
    {
        return vs;
    }

    override string fragmentShader()
    {
        return fs;
    }

    GLint colorTableLoc;
    GLint exposureLoc;
    GLint tonemapFunctionLoc;
    GLint useLUTLoc;
    GLint vignetteLoc;
    GLint useVignetteLoc;
    GLint fbVelocityLoc;
    GLint useMotionBlurLoc;
    GLint motionBlurSamplesLoc;
    GLint shutterFpsLoc;
    GLint timeStepLoc;

    bool autoExposure = false;

    float minLuminance = 0.001f;
    float maxLuminance = 100000.0f;
    float keyValue = 0.5f;
    float adaptationSpeed = 4.0f;

    float exposure = 0.5f;
    Tonemapper tonemapFunction = Tonemapper.ACES;

    GLuint velocityTexture;
    bool mblurEnabled = false;
    int motionBlurSamples = 20;
    float shutterFps = 24.0;
    float shutterSpeed = 1.0 / 24.0;

    Texture colorTable;
    Texture vignette;

    this(Framebuffer inputBuffer, Framebuffer outputBuffer, Owner o)
    {
        super(inputBuffer, outputBuffer, o);

        colorTableLoc = glGetUniformLocation(shaderProgram, "colorTable");
        exposureLoc = glGetUniformLocation(shaderProgram, "exposure");
        tonemapFunctionLoc = glGetUniformLocation(shaderProgram, "tonemapFunction");
        useLUTLoc = glGetUniformLocation(shaderProgram, "useLUT");
        vignetteLoc = glGetUniformLocation(shaderProgram, "vignette");
        useVignetteLoc = glGetUniformLocation(shaderProgram, "useVignette");
        fbVelocityLoc = glGetUniformLocation(shaderProgram, "fbVelocity");
        useMotionBlurLoc = glGetUniformLocation(shaderProgram, "useMotionBlur");
        motionBlurSamplesLoc = glGetUniformLocation(shaderProgram, "motionBlurSamples");
        shutterFpsLoc = glGetUniformLocation(shaderProgram, "shutterFps");
        timeStepLoc = glGetUniformLocation(shaderProgram, "timeStep");
    }

    override void bind(RenderingContext* rc)
    {
        super.bind(rc);

        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_2D, velocityTexture);

        glActiveTexture(GL_TEXTURE3);
        if (colorTable)
            colorTable.bind();
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glActiveTexture(GL_TEXTURE0);

        glActiveTexture(GL_TEXTURE4);
        if (vignette)
            vignette.bind();

        glActiveTexture(GL_TEXTURE0);

        glUniform1i(fbVelocityLoc, 2);
        glUniform1i(colorTableLoc, 3);
        glUniform1f(exposureLoc, exposure);
        glUniform1i(tonemapFunctionLoc, tonemapFunction);
        glUniform1i(useLUTLoc, (colorTable !is null));
        glUniform1i(vignetteLoc, 4);
        glUniform1i(useVignetteLoc, (vignette !is null));
        glUniform1i(useMotionBlurLoc, mblurEnabled);
        glUniform1i(motionBlurSamplesLoc, motionBlurSamples);
        glUniform1f(shutterFpsLoc, shutterFps);
        glUniform1f(timeStepLoc, /+rc.eventManager.deltaTime+/ 1.0f/60.0f);
    }

    override void unbind(RenderingContext* rc)
    {
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_2D, 0);

        glActiveTexture(GL_TEXTURE3);
        if (colorTable)
            colorTable.unbind();

        glActiveTexture(GL_TEXTURE4);
        if (vignette)
            vignette.unbind();
        glActiveTexture(GL_TEXTURE0);
    }
}
