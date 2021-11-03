
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

module dagon.graphics.materials.terrain2;

import std.stdio;
import std.math;

import dlib.core.memory;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.math.transformation;
import dlib.math.interpolation;
import dlib.image.color;

import derelict.opengl;

import dagon.core.ownership;
import dagon.graphics.rc;
import dagon.graphics.shadow;
import dagon.graphics.light;
import dagon.graphics.texture;
import dagon.graphics.material;
import dagon.graphics.materials.generic;

class TerrainBackend2: GLSLMaterialBackend
{
    string vsText =
    "
        #version 330 core

        uniform mat4 modelViewMatrix;
        uniform mat4 projectionMatrix;
        uniform mat4 normalMatrix;

        uniform mat4 prevModelViewProjMatrix;
        uniform mat4 blurModelViewProjMatrix;

        uniform sampler2D displacementTexture;

        layout (location = 0) in vec3 va_Vertex;
        layout (location = 1) in vec3 va_Normal;
        layout (location = 2) in vec2 va_Texcoord;
        layout (location = 3) in vec2 va_Coord;

        out vec2 texCoord;
        out vec2 coord;
        out vec3 eyePosition;
        out vec3 eyeNormal;

        out vec4 blurPosition;
        out vec4 prevPosition;

        void main()
        {
            texCoord = va_Texcoord;
            coord = va_Coord;
            eyeNormal = (normalMatrix * vec4(va_Normal, 0.0)).xyz;
            float displacement = texture(displacementTexture,coord).r;
            vec4 pos = modelViewMatrix * vec4(va_Vertex+vec3(0.0f,0.0f,displacement), 1.0);
            eyePosition = pos.xyz;

            vec4 position = projectionMatrix * pos;

            blurPosition = blurModelViewProjMatrix * vec4(va_Vertex, 1.0);
            prevPosition = prevModelViewProjMatrix * vec4(va_Vertex, 1.0);

            gl_Position = position;
        }
    ";

    string fsText =
    "
        #version 330 core

        uniform int layer;

        uniform sampler2D diffuseTexture;
        uniform sampler2D detailTexture;
        uniform sampler2D colorTexture;
        uniform sampler2D normalTexture;
        uniform sampler2D rmsTexture;
        uniform sampler2D emissionTexture;
        uniform float emissionEnergy;
        uniform float detailFactor;

        uniform int parallaxMethod;
        uniform float parallaxScale;
        uniform float parallaxBias;

        uniform float blurMask;

        in vec2 texCoord;
        in vec2 coord;
        in vec3 eyePosition;
        in vec3 eyeNormal;

        in vec4 blurPosition;
        in vec4 prevPosition;

        layout(location = 0) out vec4 frag_color;
        layout(location = 1) out vec4 frag_rms;
        layout(location = 2) out vec4 frag_position;
        layout(location = 3) out vec4 frag_normal;
        layout(location = 4) out vec4 frag_velocity;
        layout(location = 5) out vec4 frag_emission;
        layout(location = 6) out vec4 frag_information;

        mat3 cotangentFrame(in vec3 N, in vec3 p, in vec2 uv)
        {
            vec3 dp1 = dFdx(p);
            vec3 dp2 = dFdy(p);
            vec2 duv1 = dFdx(uv);
            vec2 duv2 = dFdy(uv);
            vec3 dp2perp = cross(dp2, N);
            vec3 dp1perp = cross(N, dp1);
            vec3 T = dp2perp * duv1.x + dp1perp * duv2.x;
            vec3 B = dp2perp * duv1.y + dp1perp * duv2.y;
            float invmax = inversesqrt(max(dot(T, T), dot(B, B)));
            return mat3(T * invmax, B * invmax, N);
        }

        vec2 parallaxMapping(in vec3 V, in vec2 T, out float h)
        {
            float height = texture(normalTexture, T).a;
            h = height;
            height = height * parallaxScale + parallaxBias;
            return T + (height * V.xy);
        }

        void main()
        {
            vec3 E = normalize(-eyePosition);
            vec3 N = normalize(eyeNormal);
            mat3 TBN = cotangentFrame(N, eyePosition, texCoord);
            vec3 tE = normalize(E * TBN);

            vec2 posScreen = (blurPosition.xy / blurPosition.w) * 0.5 + 0.5;
            vec2 prevPosScreen = (prevPosition.xy / prevPosition.w) * 0.5 + 0.5;
            vec2 screenVelocity = posScreen - prevPosScreen;

            // Parallax mapping
            const float heightFactor = 4;
            float detail = max(0.0,1.0-detailFactor*dot(eyePosition,eyePosition));
            float height = heightFactor*(1-texture(detailTexture, texCoord).x*detail);
            height = height * parallaxScale + parallaxBias;
            vec2 shiftedTexCoord = texCoord;// + (height * tE.xy);
            /*float height = 0.0;
            vec2 shiftedTexCoord = texCoord;
            if (parallaxMethod == 1)
                shiftedTexCoord = parallaxMapping(tE, texCoord, height);

            // Normal mapping
            vec3 tN = normalize(texture(normalTexture, shiftedTexCoord).rgb * 2.0 - 1.0);
            tN.y = -tN.y;
            N = normalize(TBN * tN);*/

            // Bump mapping
            const vec2 size = vec2(2.0,0.0);
            const ivec3 off = ivec3(-1,0,1);
            float s11 = height;
            float s01 = heightFactor*(1-textureOffset(detailTexture, texCoord, off.xy).x*detail);
            float s21 = heightFactor*(1-textureOffset(detailTexture, texCoord, off.zy).x*detail);
            float s10 = heightFactor*(1-textureOffset(detailTexture, texCoord, off.yx).x*detail);
            float s12 = heightFactor*(1-textureOffset(detailTexture, texCoord, off.yz).x*detail);
            vec3 va = normalize(vec3(size.xy,s21-s01));
            vec3 vb = normalize(vec3(size.yx,s12-s10));
            vec4 bump = vec4( cross(va,vb),s11);

            //N = normalize(TBN*bump.xyz);
            N = normalize(TBN*bump.xyz);
            // Textures
            vec4 diffuseColor = texture(diffuseTexture, shiftedTexCoord);
            vec4 detailColor = texture(detailTexture, shiftedTexCoord);
            vec4 detailAverage = textureLod(detailTexture, shiftedTexCoord, 8);
            vec4 colorColor = texture(colorTexture, coord);
            vec4 totalColor = 0.5*diffuseColor*(1.0+detailColor)*colorColor;
            vec4 rms = texture(rmsTexture, shiftedTexCoord);
            vec3 emission = texture(emissionTexture, shiftedTexCoord).rgb * emissionEnergy;

            float geomMask = float(layer > 0);

            frag_color = vec4(totalColor.rgb, geomMask);
            frag_rms = vec4(rms.r, rms.g, 1.0, 1.0);
            frag_position = vec4(eyePosition, geomMask);
            frag_normal = vec4(N, 1.0);
            frag_velocity = vec4(screenVelocity, 0.0, blurMask);
            frag_emission = vec4(emission, 1.0);
            frag_information = vec4(1,coord,1); // 1: landscape
        }
    ";

    override string vertexShaderSrc() {return vsText;}
    override string fragmentShaderSrc() {return fsText;}

    GLint layerLoc;

    GLint modelViewMatrixLoc;
    GLint projectionMatrixLoc;
    GLint normalMatrixLoc;

    GLint prevModelViewProjMatrixLoc;
    GLint blurModelViewProjMatrixLoc;

    GLint diffuseTextureLoc;
    GLint detailTextureLoc;
    GLint colorTextureLoc;
    GLint normalTextureLoc;
    GLint rmsTextureLoc;
    GLint emissionTextureLoc;
    GLint emissionEnergyLoc;
    GLint detailFactorLoc;

    GLint parallaxMethodLoc;
    GLint parallaxScaleLoc;
    GLint parallaxBiasLoc;

    GLint blurMaskLoc;

    GLint displacementTextureLoc;

    GLuint displacementFramebuffer;
    GLuint displacementTexture;
    GLuint displacementVao;
    GLuint displacementVbo;

    static class DisplacementTestBackend: GLSLMaterialBackend
    {
        string vsText = q{
            #version 330 core
            layout (location = 0) in vec2 va_Vertex;
            out vec2 position;
            void main(){
                position = va_Vertex;
                gl_Position = vec4(position,0.0f,1.0f);
            }
        };
        string fsText = q{
            #version 330 core
            uniform float time;
            in vec2 position;
            layout (location = 0) out float displacement;

            void main(){
                vec2 pos = (0.5f*(position+1.0f)*256.0f-0.5f)*10.0f;
                displacement = 2.5f*(sin(0.1f*pos.x+time)+sin(0.1f*pos.y+time));
            }
        };
        override string vertexShaderSrc(){ return vsText; }
        override string fragmentShaderSrc(){ return fsText; }

        GLint timeLoc;

        this(Owner o){
            super(o);
            timeLoc = glGetUniformLocation(shaderProgram, "time");
        }
    }
    DisplacementTestBackend displacementTest;


    this(Owner o)
    {
        super(o);

        layerLoc = glGetUniformLocation(shaderProgram, "layer");

        modelViewMatrixLoc = glGetUniformLocation(shaderProgram, "modelViewMatrix");
        projectionMatrixLoc = glGetUniformLocation(shaderProgram, "projectionMatrix");
        normalMatrixLoc = glGetUniformLocation(shaderProgram, "normalMatrix");

        prevModelViewProjMatrixLoc = glGetUniformLocation(shaderProgram, "prevModelViewProjMatrix");
        blurModelViewProjMatrixLoc = glGetUniformLocation(shaderProgram, "blurModelViewProjMatrix");

        diffuseTextureLoc = glGetUniformLocation(shaderProgram, "diffuseTexture");
        detailTextureLoc = glGetUniformLocation(shaderProgram, "detailTexture");
        colorTextureLoc = glGetUniformLocation(shaderProgram, "colorTexture");
        normalTextureLoc = glGetUniformLocation(shaderProgram, "normalTexture");
        rmsTextureLoc = glGetUniformLocation(shaderProgram, "rmsTexture");
        emissionTextureLoc = glGetUniformLocation(shaderProgram, "emissionTexture");
        emissionEnergyLoc = glGetUniformLocation(shaderProgram, "emissionEnergy");
        detailFactorLoc = glGetUniformLocation(shaderProgram, "detailFactor");

        parallaxMethodLoc = glGetUniformLocation(shaderProgram, "parallaxMethod");
        parallaxScaleLoc = glGetUniformLocation(shaderProgram, "parallaxScale");
        parallaxBiasLoc = glGetUniformLocation(shaderProgram, "parallaxBias");

        blurMaskLoc = glGetUniformLocation(shaderProgram, "blurMask");

        displacementTextureLoc = glGetUniformLocation(shaderProgram, "displacementTexture");

        glGenFramebuffers(1, &displacementFramebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, displacementFramebuffer);
        glGenTextures(1, &displacementTexture);
        glBindTexture(GL_TEXTURE_2D, displacementTexture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_R32F, 256, 256, 0, GL_RED, GL_FLOAT, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glFramebufferTexture(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, displacementTexture, 0);
        GLenum[1] drawBuffers = [GL_COLOR_ATTACHMENT0];
        glDrawBuffers(1, drawBuffers.ptr);
        GLenum status=glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if(status!=GL_FRAMEBUFFER_COMPLETE)
            writeln(status);

        static immutable GLfloat[] g_quad_vertex_buffer_data = [
            -1.0f, -1.0f,
            1.0f, -1.0f,
            -1.0f, 1.0f,
            -1.0f, 1.0f,
            1.0f, -1.0f,
            1.0f,  1.0f,
        ];

        glGenBuffers(1, &displacementVbo);
        glBindBuffer(GL_ARRAY_BUFFER, displacementVbo);
        glBufferData(GL_ARRAY_BUFFER, float.sizeof*g_quad_vertex_buffer_data.length, g_quad_vertex_buffer_data.ptr, GL_STATIC_DRAW);

        glGenVertexArrays(1, &displacementVao);
        glBindVertexArray(displacementVao);
        glEnableVertexAttribArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, displacementVbo);
        glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,0,cast(void*)0);

        displacementTest = New!DisplacementTestBackend(this);
    }

    final void bindDisplacement(){
        glBindFramebuffer(GL_FRAMEBUFFER, displacementFramebuffer);
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE);
        glDepthMask(0);
        glDisable(GL_DEPTH_TEST);
        glViewport(0,0,256,256);
        glScissor(0,0,256,256);
        glClearColor(0.0f,0.0f,0.0f,0.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glBindVertexArray(displacementVao);
    }

    final void drawTestDisplacement(float time){
        displacementTest.bind(null,null);
        glUniform1f(displacementTest.timeLoc,time);
        glDrawArrays(GL_TRIANGLES, 0, 6);
        displacementTest.unbind(null,null);
    }
    final void unbindDisplacement(){
        glBindVertexArray(0);
        glEnable(GL_DEPTH_TEST);
        glDepthMask(1);
        glDisable(GL_BLEND);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }

    final void bindColor(Texture color){
        glActiveTexture(GL_TEXTURE5);
        color.bind();
        glUniform1i(colorTextureLoc, 5);
    }
    final void bindDiffuse(Texture diffuse){
        glActiveTexture(GL_TEXTURE0);
        diffuse.bind();
    }
    Texture defaultDetail=null;
    final void bindDetail(Texture detail){
        if(!detail){
            if(!defaultDetail) defaultDetail=makeOnePixelTexture(null, Color4f(0,0,0)); // TODO: fix memory leak?
            detail=defaultDetail;
        }
        glActiveTexture(GL_TEXTURE4);
        detail.bind();
        glUniform1i(detailTextureLoc, 4);
    }
    final void bindEmission(Texture emission){
        glActiveTexture(GL_TEXTURE3);
        emission.bind();
        glUniform1i(emissionTextureLoc, 3);
    }

    final void setModelViewMatrix(Matrix4x4f modelViewMatrix){
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(normalMatrixLoc, 1, GL_FALSE, modelViewMatrix.arrayof.ptr); // valid for rotation-translations
    }
    final void setAlpha(float alpha){ }
    final void setInformation(Vector4f information){
        assert(0, "can't set custom information for terrain.");
    }

    override void bind(GenericMaterial mat, RenderingContext* rc)
    {
        //auto inormal = "normal" in mat.inputs;
        //auto iheight = "height" in mat.inputs;
        auto ipbr = "pbr" in mat.inputs;
        auto iroughness = "roughness" in mat.inputs;
        auto imetallic = "metallic" in mat.inputs;
        auto iEnergy = "energy" in mat.inputs;
        auto iDetailFactor = "detailFactor" in mat.inputs;
        auto iDisplacement = "displacement" in mat.inputs;

        int parallaxMethod = intProp(mat, "parallax");
        if (parallaxMethod > ParallaxOcclusionMapping)
            parallaxMethod = ParallaxOcclusionMapping;
        if (parallaxMethod < 0)
            parallaxMethod = 0;

        glUseProgram(shaderProgram);

        glUniform1i(layerLoc, rc.layer);

        glUniform1f(blurMaskLoc, rc.blurMask);

        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, rc.modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(projectionMatrixLoc, 1, GL_FALSE, rc.projectionMatrix.arrayof.ptr);
        glUniformMatrix4fv(normalMatrixLoc, 1, GL_FALSE, rc.normalMatrix.arrayof.ptr);

        glUniformMatrix4fv(prevModelViewProjMatrixLoc, 1, GL_FALSE, rc.prevModelViewProjMatrix.arrayof.ptr);
        glUniformMatrix4fv(blurModelViewProjMatrixLoc, 1, GL_FALSE, rc.blurModelViewProjMatrix.arrayof.ptr);


        // Texture 1 - normal map + parallax map
        float parallaxScale = 0.03f;
        float parallaxBias = -0.01f;
        /+bool normalTexturePrepared = inormal.texture !is null;
        if (normalTexturePrepared)
            normalTexturePrepared = inormal.texture.image.channels == 4;
        if (!normalTexturePrepared)
        {
            if (inormal.texture is null)
            {
                Color4f color = Color4f(0.5f, 0.5f, 1.0f, 0.0f); // default normal pointing upwards
                inormal.texture = makeOnePixelTexture(mat, color);
            }
            else
            {
                if (iheight.texture !is null)
                    packAlphaToTexture(inormal.texture, iheight.texture);
                else
                    packAlphaToTexture(inormal.texture, 0.0f);
            }
        }
        glActiveTexture(GL_TEXTURE1);
        inormal.texture.bind();
        glUniform1i(normalTextureLoc, 1);+/
        glUniform1f(parallaxScaleLoc, parallaxScale);
        glUniform1f(parallaxBiasLoc, parallaxBias);
        //glUniform1i(parallaxMethodLoc, parallaxMethod);

        // Texture 2 - PBR maps (roughness + metallic)
        if (ipbr is null)
        {
            mat.setInput("pbr", 0.0f);
            ipbr = "pbr" in mat.inputs;
        }

        if (ipbr.texture is null)
        {
            ipbr.texture = makeTextureFrom(mat, *iroughness, *imetallic, materialInput(0.0f), materialInput(0.0f));
        }
        glActiveTexture(GL_TEXTURE2);
        glUniform1i(rmsTextureLoc, 2);
        ipbr.texture.bind();

        glActiveTexture(GL_TEXTURE6);
        glBindTexture(GL_TEXTURE_2D, displacementTexture);
        glUniform1i(displacementTextureLoc, 6);

        glUniform1f(emissionEnergyLoc, iEnergy.asFloat);
        float detailFactor=1.5e-4f;
        if(iDetailFactor) detailFactor=iDetailFactor.asFloat;
        glUniform1f(detailFactorLoc, detailFactor);

        glActiveTexture(GL_TEXTURE0);
    }

    override void unbind(GenericMaterial mat, RenderingContext* rc)
    {
        auto ipbr = "pbr" in mat.inputs;
        auto iemission = "emission" in mat.inputs;

        glActiveTexture(GL_TEXTURE2);
        ipbr.texture.unbind();

        glActiveTexture(GL_TEXTURE6);
        glBindTexture(GL_TEXTURE_2D, 0);

        glActiveTexture(GL_TEXTURE0);

        glUseProgram(0);
    }
}
