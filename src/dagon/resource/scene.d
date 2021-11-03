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

module dagon.resource.scene;

import std.stdio;
import std.math;
import std.algorithm;

import dlib.core.memory;

import dlib.container.array;
import dlib.container.dict;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.math.transformation;
import dlib.image.color;

import derelict.opengl;

import dagon.core.ownership;
import dagon.core.event;
import dagon.core.application;
import dagon.resource.asset;
import dagon.resource.textasset;
import dagon.resource.textureasset;
import dagon.resource.fontasset;
import dagon.resource.obj;
import dagon.resource.iqm;
import dagon.resource.packageasset;
import dagon.graphics.environment;
import dagon.graphics.rc;
import dagon.graphics.view;
import dagon.graphics.shapes;
import dagon.graphics.light;
import dagon.graphics.shadow;
import dagon.graphics.texture;
import dagon.graphics.particles;
import dagon.graphics.materials.generic;
import dagon.graphics.materials.bone;
import dagon.graphics.materials.terrain2;
import dagon.graphics.materials.shadeless;
import dagon.graphics.materials.shadelessBone;
import dagon.graphics.materials.buildingSummon;
import dagon.graphics.materials.sacSky;
import dagon.graphics.materials.sacSun;
import dagon.graphics.materials.sky;
import dagon.graphics.materials.hud;
import dagon.graphics.materials.hud2;
import dagon.graphics.materials.cooldown;
import dagon.graphics.materials.colorHUD;
import dagon.graphics.materials.colorHUD2;
import dagon.graphics.materials.minimap;
import dagon.graphics.materials.particle;
import dagon.graphics.framebuffer;
import dagon.graphics.gbuffer;
import dagon.graphics.deferred;
import dagon.graphics.postproc;
import dagon.graphics.filters.fxaa;
import dagon.graphics.filters.lens;
import dagon.graphics.filters.hdrprepass;
import dagon.graphics.filters.hdr;
import dagon.graphics.filters.blur;
import dagon.graphics.filters.finalizer;
import dagon.logics.entity;

class BaseScene: EventListener
{
    SceneManager sceneManager;
    AssetManager assetManager;
    bool canRun = false;
    bool releaseAtNextStep = false;
    bool needToLoad = true;

    this(SceneManager smngr)
    {
        super(smngr.eventManager, null);
        sceneManager = smngr;
        assetManager = New!AssetManager(eventManager);
    }

    ~this()
    {
        release();
        Delete(assetManager);
    }

    // Set preload to true if you want to load the asset immediately
    // before actual loading (e.g., to render a loading screen)

    Asset addAsset(Asset asset, string filename, bool preload = false)
    {
        if (preload)
            assetManager.preloadAsset(asset, filename);
        else
            assetManager.addAsset(asset, filename);
        return asset;
    }

    void onAssetsRequest()
    {
        // Add your assets here
    }

    void onLoading(float percentage)
    {
        // Render your loading screen here
    }

    void onAllocate()
    {
        // Allocate your objects here
    }

    void onRelease()
    {
        // Release your objects here
    }

    void onStart()
    {
        // Do your (re)initialization here
    }

    void onEnd()
    {
        // Do your finalization here
    }

    void onUpdate(double dt)
    {
        // Do your animation and logics here
    }

    void onRender()
    {
        // Do your rendering here
    }

    void exitApplication()
    {
        generateUserEvent(DagonEvent.Exit);
    }

    void load()
    {
        if (needToLoad)
        {
            onAssetsRequest();
            float p = assetManager.nextLoadingPercentage;

            assetManager.loadThreadSafePart();

            while(assetManager.isLoading)
            {
                sceneManager.application.beginRender();
                onLoading(p);
                sceneManager.application.endRender();
                p = assetManager.nextLoadingPercentage;
            }

            bool loaded = assetManager.loadThreadUnsafePart();

            if (loaded)
            {
                onAllocate();
                canRun = true;
                needToLoad = false;
            }
            else
            {
                writeln("Exiting due to error while loading assets");
                canRun = false;
                eventManager.running = false;
            }
        }
        else
        {
            canRun = true;
        }
    }

    void release()
    {
        onRelease();
        clearOwnedObjects();
        assetManager.releaseAssets();
        needToLoad = true;
        canRun = false;
    }

    void start()
    {
        if (canRun)
            onStart();
    }

    void end()
    {
        if (canRun)
            onEnd();
    }

    void update(double dt)
    {
        if (canRun)
        {
            eventManager.update();
            processEvents();
            assetManager.updateMonitor(dt);
            onUpdate(dt);
        }

        if (releaseAtNextStep)
        {
            end();
            release();

            releaseAtNextStep = false;
            canRun = false;
        }
    }

    void render()
    {
        if (canRun)
            onRender();
    }
}

class SceneManager: Owner
{
    SceneApplication application;
    Dict!(BaseScene, string) scenesByName;
    EventManager eventManager;
    BaseScene currentScene;

    this(EventManager emngr, SceneApplication app)
    {
        super(app);
        application = app;
        eventManager = emngr;
        scenesByName = New!(Dict!(BaseScene, string));
    }

    ~this()
    {
        foreach(i, s; scenesByName)
        {
            Delete(s);
        }
        Delete(scenesByName);
    }

    BaseScene addScene(BaseScene scene, string name)
    {
        scenesByName[name] = scene;
        return scene;
    }

    void removeScene(string name)
    {
        Delete(scenesByName[name]);
        scenesByName.remove(name);
    }

    void goToScene(string name, bool releaseCurrent = true)
    {
        if (currentScene && releaseCurrent)
        {
            currentScene.releaseAtNextStep = true;
        }

        BaseScene scene = scenesByName[name];

        //writefln("Loading scene \"%s\"", name);

        scene.load();
        currentScene = scene;
        currentScene.start();

        //writefln("Running...", name);
    }

    void update(double dt)
    {
        if (currentScene)
        {
            currentScene.update(dt);
        }
    }

    void render()
    {
        if (currentScene)
        {
            currentScene.render();
        }
    }
}

class SceneApplication: Application
{
    SceneManager sceneManager;

    this(uint w, uint h, bool fullscreen, string windowTitle, string[] args)
    {
        super(w, h, fullscreen, windowTitle, args);

        sceneManager = New!SceneManager(eventManager, this);
    }

    override void onUpdate(double dt)
    {
        sceneManager.update(dt);
    }

    override void onRender()
    {
        sceneManager.render();
    }
}

class Scene: BaseScene
{
    Environment environment;

    LightManager lightManager;
    CascadedShadowMap shadowMap;
    ParticleSystem particleSystem;

    GeometryPassBackend defaultMaterialBackend;
    GenericMaterial defaultMaterial3D;

    //ParticleBackend particleMaterialBackend;

    BoneBackend boneMaterialBackend;
    TerrainBackend2 terrainMaterialBackend;
    ShadelessBackend shadelessMaterialBackend;
    ShadelessBoneBackend shadelessBoneMaterialBackend;
    BuildingSummonBackend1 buildingSummonMaterialBackend1;
    BuildingSummonBackend2 buildingSummonMaterialBackend2;
    SacSkyBackend sacSkyMaterialBackend;
    SacSunBackend sacSunMaterialBackend;

    SkyBackend skyMaterialBackend;

    RenderingContext rc3d;
    RenderingContext rc2d;
    View view;

    GBuffer[1] gbuffers;
    static if(gbuffers.length!=1) int curGBuffer=0;
    else enum curGBuffer=0;

    @property final GBuffer gbuffer(){
        return gbuffers[curGBuffer];
    }
    DeferredEnvironmentPass deferredEnvPass;
    DeferredLightPass deferredLightPass;

    Framebuffer sceneFramebuffer;
    PostFilterHDR hdrFilter;

    Framebuffer hdrPrepassFramebuffer;
    PostFilterHDRPrepass hdrPrepassFilter;

    Framebuffer hblurredFramebuffer;
    Framebuffer vblurredFramebuffer;
    PostFilterBlur hblur;
    PostFilterBlur vblur;

    PostFilterFXAA fxaaFilter;
    PostFilterLensDistortion lensFilter;

    PostFilterFinalizer finalizerFilter;

    struct SSAOSettings
    {
        BaseScene3D scene;

        void enabled(bool mode) @property
        {
            scene.deferredEnvPass.enableSSAO = mode;
        }

        bool enabled() @property
        {
            return scene.deferredEnvPass.enableSSAO;
        }

        //TODO: other SSAO parameters
    }

    struct HDRSettings
    {
        BaseScene3D scene;

        void tonemapper(Tonemapper f) @property
        {
            scene.hdrFilter.tonemapFunction = f;
        }

        Tonemapper tonemapper() @property
        {
            return scene.hdrFilter.tonemapFunction;
        }


        void exposure(float ex) @property
        {
            scene.hdrFilter.exposure = ex;
        }

        float exposure() @property
        {
            return scene.hdrFilter.exposure;
        }


        void autoExposure(bool mode) @property
        {
            scene.hdrFilter.autoExposure = mode;
        }

        bool autoExposure() @property
        {
            return scene.hdrFilter.autoExposure;
        }


        void minLuminance(float l) @property
        {
            scene.hdrFilter.minLuminance = l;
        }

        float minLuminance() @property
        {
            return scene.hdrFilter.minLuminance;
        }


        void maxLuminance(float l) @property
        {
            scene.hdrFilter.maxLuminance = l;
        }

        float maxLuminance() @property
        {
            return scene.hdrFilter.maxLuminance;
        }


        void keyValue(float k) @property
        {
            scene.hdrFilter.keyValue = k;
        }

        float keyValue() @property
        {
            return scene.hdrFilter.keyValue;
        }


        void adaptationSpeed(float s) @property
        {
            scene.hdrFilter.adaptationSpeed = s;
        }

        float adaptationSpeed() @property
        {
            return scene.hdrFilter.adaptationSpeed;
        }
    }

    struct GlowSettings
    {
        BaseScene3D scene;
        uint radius;

        void enabled(bool mode) @property
        {
            scene.hblur.enabled = mode;
            scene.vblur.enabled = mode;
            scene.hdrPrepassFilter.glowEnabled = mode;
        }

        bool enabled() @property
        {
            return scene.hdrPrepassFilter.glowEnabled;
        }


        void brightness(float b) @property
        {
            scene.hdrPrepassFilter.glowBrightness = b;
        }

        float brightness() @property
        {
            return scene.hdrPrepassFilter.glowBrightness;
        }
    }

    struct MotionBlurSettings
    {
        BaseScene3D scene;

        void enabled(bool mode) @property
        {
            scene.hdrFilter.mblurEnabled = mode;
        }

        bool enabled() @property
        {
            return scene.hdrFilter.mblurEnabled;
        }


        void samples(uint s) @property
        {
            scene.hdrFilter.motionBlurSamples = s;
        }

        uint samples() @property
        {
            return scene.hdrFilter.motionBlurSamples;
        }


        void shutterSpeed(float s) @property
        {
            scene.hdrFilter.shutterSpeed = s;
            scene.hdrFilter.shutterFps = 1.0 / s;
        }

        float shutterSpeed() @property
        {
            return scene.hdrFilter.shutterSpeed;
        }
    }

    struct LUTSettings
    {
        BaseScene3D scene;

        void texture(Texture tex) @property
        {
            scene.hdrFilter.colorTable = tex;
        }

        Texture texture() @property
        {
            return scene.hdrFilter.colorTable;
        }
    }

    struct VignetteSettings
    {
        BaseScene3D scene;

        void texture(Texture tex) @property
        {
            scene.hdrFilter.vignette = tex;
        }

        Texture texture() @property
        {
            return scene.hdrFilter.vignette;
        }
    }

    struct AASettings
    {
        BaseScene3D scene;

        void enabled(bool mode) @property
        {
            scene.fxaaFilter.enabled = mode;
        }

        bool enabled() @property
        {
            return scene.fxaaFilter.enabled;
        }
    }

    struct LensSettings
    {
        BaseScene3D scene;

        void enabled(bool mode) @property
        {
            scene.lensFilter.enabled = mode;
        }

        bool enabled() @property
        {
            return scene.lensFilter.enabled;
        }

        void scale(float s) @property
        {
            scene.lensFilter.scale = s;
        }

        float scale() @property
        {
            return scene.lensFilter.scale;
        }


        void dispersion(float d) @property
        {
            scene.lensFilter.dispersion = d;
        }

        float dispersion() @property
        {
            return scene.lensFilter.dispersion;
        }
    }

    SSAOSettings ssao;
    HDRSettings hdr;
    MotionBlurSettings motionBlur;
    GlowSettings glow;
    LUTSettings lut;
    VignetteSettings vignette;
    AASettings antiAliasing;
    LensSettings lensDistortion;

    DynamicArray!PostFilter postFilters;

    DynamicArray!Entity entities3D;
    DynamicArray!Entity entities2D;

    ShapeQuad loadingProgressBar;
    Entity eLoadingProgressBar;
    HUDMaterialBackend hudMaterialBackend;
    HUDMaterialBackend2 hudMaterialBackend2;
    CooldownMaterialBackend cooldownMaterialBackend;
    ColorHUDMaterialBackend colorHUDMaterialBackend;
    ColorHUDMaterialBackend2 colorHUDMaterialBackend2;
    MinimapMaterialBackend minimapMaterialBackend;
    GenericMaterial mLoadingProgressBar;

    double timer = 0.0;
    double fixedTimeStep = 1.0 / 60.0;

    int width, height;
    float screenScaling;
    float aspectDistortion;

    this(int width, int height, float screenScaling, float aspectDistortion, SceneManager smngr)
    in
    {
        assert(width&&height);
    }
    do
    {
        super(smngr);
        this.width=width;
        this.height=height;
        this.screenScaling=screenScaling;
        this.aspectDistortion=aspectDistortion;

        rc3d.init(width, height, environment);
        auto aspectRatio = cast(float)width/cast(float)height*aspectDistortion;
        rc3d.projectionMatrix = perspectiveMatrix(62.0f, aspectRatio, 0.1f, 10000.0f);

        rc2d.init(width, height, environment);
        rc2d.projectionMatrix = orthoMatrix(0.0f, width, 0.0f, height, 0.0f, 100.0f);

        loadingProgressBar = New!ShapeQuad(assetManager);
        eLoadingProgressBar = New!Entity(eventManager, assetManager);
        eLoadingProgressBar.drawable = loadingProgressBar;
        hudMaterialBackend = New!HUDMaterialBackend(assetManager);
        hudMaterialBackend2 = New!HUDMaterialBackend2(assetManager);
        cooldownMaterialBackend = New!CooldownMaterialBackend(assetManager);
        colorHUDMaterialBackend = New!ColorHUDMaterialBackend(assetManager);
        colorHUDMaterialBackend2 = New!ColorHUDMaterialBackend2(assetManager);
        minimapMaterialBackend = New!MinimapMaterialBackend(assetManager);
        mLoadingProgressBar = createMaterial(hudMaterialBackend);
        mLoadingProgressBar.diffuse = Color4f(1, 1, 1, 1);
        eLoadingProgressBar.material = mLoadingProgressBar;
    }

    static void sortEntities(ref DynamicArray!Entity entities)
    {
        import std.algorithm;
        static struct Wtf{
            Entity x;
        }
        sort!"a.x.layer<b.x.layer"(cast(Wtf[])entities.data);
        foreach(v;entities.data)
            sortEntities(v.children);
    }

    TextAsset addTextAsset(string filename, bool preload = false)
    {
        TextAsset text;
        if (assetManager.assetExists(filename))
            text = cast(TextAsset)assetManager.getAsset(filename);
        else
        {
            text = New!TextAsset(assetManager);
            addAsset(text, filename, preload);
        }
        return text;
    }

    TextureAsset addTextureAsset(string filename, bool preload = false)
    {
        TextureAsset tex;
        if (assetManager.assetExists(filename))
            tex = cast(TextureAsset)assetManager.getAsset(filename);
        else
        {
            tex = New!TextureAsset(assetManager.imageFactory, assetManager.hdrImageFactory, assetManager);
            addAsset(tex, filename, preload);
        }
        return tex;
    }

    FontAsset addFontAsset(string filename, uint height, bool preload = false)
    {
        FontAsset font;
        if (assetManager.assetExists(filename))
            font = cast(FontAsset)assetManager.getAsset(filename);
        else
        {
            font = New!FontAsset(height, assetManager);
            addAsset(font, filename, preload);
        }
        return font;
    }

    OBJAsset addOBJAsset(string filename, bool preload = false)
    {
        OBJAsset obj;
        if (assetManager.assetExists(filename))
            obj = cast(OBJAsset)assetManager.getAsset(filename);
        else
        {
            obj = New!OBJAsset(assetManager);
            addAsset(obj, filename, preload);
        }
        return obj;
    }

    IQMAsset addIQMAsset(string filename, bool preload = false)
    {
        IQMAsset iqm;
        if (assetManager.assetExists(filename))
            iqm = cast(IQMAsset)assetManager.getAsset(filename);
        else
        {
            iqm = New!IQMAsset(assetManager);
            addAsset(iqm, filename, preload);
        }
        return iqm;
    }

    PackageAsset addPackageAsset(string filename, bool preload = false)
    {
        PackageAsset pa;
        if (assetManager.assetExists(filename))
            pa = cast(PackageAsset)assetManager.getAsset(filename);
        else
        {
            pa = New!PackageAsset(this, assetManager);
            addAsset(pa, filename, preload);
        }
        return pa;
    }

    Entity createEntity2D(Entity parent = null)
    {
        Entity e;
        if (parent)
            e = New!Entity(parent);
        else
        {
            e = New!Entity(eventManager, assetManager);
            entities2D.append(e);

            //sortEntities(entities2D);
        }

        return e;
    }

    Entity createEntity3D(Entity parent = null)
    {
        Entity e;
        if (parent)
            e = New!Entity(parent);
        else
        {
            e = New!Entity(eventManager, assetManager);
            entities3D.append(e);

            //sortEntities(entities3D);
        }

        e.material = defaultMaterial3D;

        return e;
    }

    Entity addEntity3D(Entity e)
    {
        entities3D.append(e);
        //sortEntities(entities3D);
        return e;
    }

    Entity createSky()
    {
        auto matSky = createMaterial(skyMaterialBackend);
        matSky.depthWrite = false;

        auto eSky = createEntity3D();
        eSky.layer = 0;
        eSky.attach = Attach.Camera;
        eSky.castShadow = false;
        eSky.material = matSky;
        eSky.drawable = New!ShapeSphere(1.0f, 16, 8, true, assetManager); //aSphere.mesh;
        eSky.scaling = Vector3f(100.0f, 100.0f, 100.0f);
        //sortEntities(entities3D);
        return eSky;
    }

    GenericMaterial createMaterial(GenericMaterialBackend backend = null)
    {
        if (backend is null)
            backend = defaultMaterialBackend;
        return New!GenericMaterial(backend, assetManager);
    }

    /+GenericMaterial createParticleMaterial(GenericMaterialBackend backend = null)
    {
        if (backend is null)
            backend = particleMaterialBackend;
        return New!GenericMaterial(backend, assetManager);
    }+/

    LightSource createLight(Vector3f position, Color4f color, float energy, float volumeRadius, float areaRadius = 0.0f)
    {
        return lightManager.addLight(position, color, energy, volumeRadius, areaRadius);
    }

    int shadowMapResolution=8192;
    override void onAllocate()
    {
        environment = New!Environment(assetManager);

        lightManager = New!LightManager(200.0f, 100, assetManager);

        defaultMaterialBackend = New!GeometryPassBackend(assetManager);
        boneMaterialBackend = New!BoneBackend(assetManager);
        terrainMaterialBackend = New!TerrainBackend2(assetManager);
        shadelessMaterialBackend = New!ShadelessBackend(assetManager);
        shadelessBoneMaterialBackend = New!ShadelessBoneBackend(assetManager);
        buildingSummonMaterialBackend1 = New!BuildingSummonBackend1(assetManager);
        buildingSummonMaterialBackend2 = New!BuildingSummonBackend2(assetManager);
        sacSkyMaterialBackend = New!SacSkyBackend(assetManager);
        sacSunMaterialBackend = New!SacSunBackend(assetManager);
        skyMaterialBackend = New!SkyBackend(assetManager);

        shadowMap = New!CascadedShadowMap(shadowMapResolution, this, cast(float[3])[50, 200, 1280], -10000, 10000, assetManager);

        particleSystem = New!ParticleSystem(assetManager);

        defaultMaterial3D = createMaterial();

        foreach(i;0..gbuffers.length)
            gbuffers[i] = New!GBuffer(width, height, this, assetManager);
        deferredEnvPass = New!DeferredEnvironmentPass(gbuffer, shadowMap, assetManager);
        deferredLightPass = New!DeferredLightPass(gbuffer, lightManager, assetManager);

        sceneFramebuffer = New!Framebuffer(width, height, true, true, assetManager);

        ssao.scene = this;
        hdr.scene = this;
        motionBlur.scene = this;
        glow.scene = this;
        glow.radius = 3;
        lut.scene = this;
        vignette.scene = this;
        antiAliasing.scene = this;
        lensDistortion.scene = this;

        hblurredFramebuffer = New!Framebuffer(width / 2, height / 2, true, false, assetManager);
        hblur = New!PostFilterBlur(true, sceneFramebuffer, hblurredFramebuffer, assetManager);

        vblurredFramebuffer = New!Framebuffer(width / 2, height / 2, true, false, assetManager);
        vblur = New!PostFilterBlur(false, hblurredFramebuffer, vblurredFramebuffer, assetManager);

        hdrPrepassFramebuffer = New!Framebuffer(width, height, true, false, assetManager);
        hdrPrepassFilter = New!PostFilterHDRPrepass(sceneFramebuffer, hdrPrepassFramebuffer, assetManager);
        hdrPrepassFilter.blurredTexture = vblurredFramebuffer.colorTexture;
        postFilters.append(hdrPrepassFilter);

        hdrFilter = New!PostFilterHDR(hdrPrepassFramebuffer, null, assetManager);
        hdrFilter.velocityTexture = gbuffer.velocityTexture; //sceneFramebuffer.velocityTexture;
        postFilters.append(hdrFilter);

        fxaaFilter = New!PostFilterFXAA(null, null, assetManager);
        postFilters.append(fxaaFilter);
        fxaaFilter.enabled = false;

        /+lensFilter = New!PostFilterLensDistortion(null, null, assetManager);
        postFilters.append(lensFilter);
        lensFilter.enabled = false;+/

        finalizerFilter = New!PostFilterFinalizer(null, null, assetManager);

        // particleMaterialBackend = New!ParticleBackend(gbuffer, assetManager);
    }

    PostFilter addFilter(PostFilter f)
    {
        postFilters.append(f);
        return f;
    }

    override void onRelease()
    {
        entities3D.free();
        entities2D.free();

        postFilters.free();
    }

    override void onLoading(float percentage)
    {
        glEnable(GL_SCISSOR_TEST);
        auto yOffset=eventManager.windowHeight-height;
        glScissor(0, 0+yOffset, width, height);
        glViewport(0, 0+yOffset, width, height);
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        float maxWidth = width * 0.33f;
        float x = (width - maxWidth) * 0.5f;
        float y = height * 0.5f - 10;
        float w = percentage * maxWidth;

        glDisable(GL_DEPTH_TEST);
        mLoadingProgressBar.diffuse = Color4f(0.1, 0.1, 0.1, 1);
        eLoadingProgressBar.position = Vector3f(x, y, 0);
        eLoadingProgressBar.scaling = Vector3f(maxWidth, 10, 1);
        eLoadingProgressBar.update(1.0/60.0);
        eLoadingProgressBar.render(&rc2d);

        mLoadingProgressBar.diffuse = Color4f(1, 1, 1, 1);
        eLoadingProgressBar.scaling = Vector3f(w, 10, 1);
        eLoadingProgressBar.update(1.0/60.0);
        eLoadingProgressBar.render(&rc2d);
    }

    override void onStart()
    {
        auto aspectRatio=cast(float)width/cast(float)height*aspectDistortion;
        rc3d.initPerspective(width, height, aspectRatio, environment, 62.0f, 0.1f, 10000.0f);
        rc2d.initOrtho(width, height, environment, 0.0f, 100.0f);

        timer = 0.0;
        onViewUpdate(0.0f);
    }

    void onViewUpdate(double dt){
        if (view)
        {
            view.update(dt);
            view.prepareRC(&rc3d);
            Vector3f cameraDirection = -view.invViewMatrix.forward;
            //cameraDirection.y = 0.0f;
            //cameraDirection = cameraDirection.normalized;
            Vector3f round(Vector3f a, float resolution){
                return Vector3f(a.x-fmod(a.x,resolution), a.y-fmod(a.y,resolution), a.z-fmod(a.z,resolution));
            }
            auto res1=shadowMap.projSize[0]/shadowMapResolution*5;
            shadowMap.area[0].position = round(view.cameraPosition + cameraDirection * (shadowMap.projSize[0]  * 0.48f - 1.0f), res1);
            foreach(i;1..shadowMap.projSize.length){
                auto res=shadowMap.projSize[i]/shadowMapResolution*(i==1?10:100);
                shadowMap.area[i].position = round(view.cameraPosition + cameraDirection * shadowMap.projSize[i] * 0.5f, res);
            }
            //shadowMap.area[2].position = Vector3f(1280,1280,0);
        }

        shadowMap.update(&rc3d, dt);
        lightManager.update(&rc3d);
    }

    void onLogicsUpdate(double dt)
    {
    }

    override void onUpdate(double dt)
    {
/+        foreach(e; entities3D)
            e.processEvents();

        foreach(e; entities2D)
            e.processEvents();+/
        timer += dt;
        while (timer >= fixedTimeStep)
        {
            timer -= fixedTimeStep;

/+
            foreach(e; entities3D)
                e.update(fixedTimeStep);

            foreach(e; entities2D)
                e.update(fixedTimeStep);
+/
            //particleSystem.update(fixedTimeStep);

            onLogicsUpdate(fixedTimeStep);

            //environment.update(fixedTimeStep);
        }
        rc3d.time += dt;
        rc2d.time += dt;

        onViewUpdate(dt);
    }

    void renderShadows(RenderingContext* rc)
    {
        shadowMap.render(rc);
    }

    void renderShadowCastingEntities3D(RenderingContext* rc){
        foreach(e; entities3D)
            if (e.castShadow)
                e.render(rc);
    }

    void renderBackgroundEntities3D(RenderingContext* rc)
    {
        glEnable(GL_DEPTH_TEST);
        foreach(e; entities3D)
            if (e.layer <= 0)
                e.render(rc);
    }

    // TODO: check transparency of children (use context variable)
    void renderOpaqueEntities3D(RenderingContext* rc)
    {
        glEnable(GL_DEPTH_TEST);
        RenderingContext rcLocal = *rc;
        rcLocal.ignoreTransparentEntities = true;
        foreach(e; entities3D)
        {
            if (e.layer > 0)
                e.render(&rcLocal);
        }
    }

    // TODO: check transparency of children (use context variable)
    void renderTransparentEntities3D(RenderingContext* rc)
    {
        glEnable(GL_DEPTH_TEST);
        RenderingContext rcLocal = *rc;
        rcLocal.ignoreOpaqueEntities = true;
        foreach(e; entities3D)
        {
            if (e.layer > 0)
                e.render(&rcLocal);
        }
    }

    void renderEntities3D(RenderingContext* rc)
    {
        glEnable(GL_DEPTH_TEST);
        foreach(e; entities3D)
            e.render(rc);
    }

    void renderEntities2D(RenderingContext* rc)
    {
        glDisable(GL_DEPTH_TEST);
        foreach(e; entities2D)
            e.render(rc);
    }

    void prepareViewport(Framebuffer b = null, bool move=false)
    {
        glEnable(GL_SCISSOR_TEST);
        int width=this.width, height=this.height, yOffset=0;
        if(move){
            width=cast(int)(width*screenScaling);
            height=cast(int)(height*screenScaling);
            yOffset=eventManager.windowHeight-height;
        }
        if (b)
        {
            glScissor(0, 0+yOffset, b.width, b.height);
            glViewport(0, 0+yOffset, b.width, b.height);
        }
        else
        {
            glScissor(0, 0+yOffset, width, height);
            glViewport(0, 0+yOffset, width, height);
        }
        if (environment)
            glClearColor(environment.backgroundColor.r, environment.backgroundColor.g, environment.backgroundColor.b, 0.0f);
    }

    void renderBlur(uint iterations)
    {
        RenderingContext rcTmp;

        foreach(i; 1..iterations+1)
        {
            hblur.outputBuffer.bind();
            rcTmp.initOrtho(width, height, environment, hblur.outputBuffer.width, hblur.outputBuffer.height, 0.0f, 100.0f);
            prepareViewport(hblur.outputBuffer);
            hblur.radius = i;
            hblur.render(&rcTmp);
            hblur.outputBuffer.unbind();

            vblur.outputBuffer.bind();
            rcTmp.initOrtho(width, height, environment, vblur.outputBuffer.width, vblur.outputBuffer.height, 0.0f, 100.0f);
            prepareViewport(vblur.outputBuffer);
            vblur.radius = i;
            vblur.render(&rcTmp);
            vblur.outputBuffer.unbind();

            hblur.inputBuffer = vblur.outputBuffer;
        }

        hblur.inputBuffer = sceneFramebuffer;
    }

    void startGBufferInformationDownload(){ }

    final void testDisplacement(float time){
        terrainMaterialBackend.drawTestDisplacement(time);
    }

    abstract bool needTerrainDisplacement();
    abstract void displaceTerrain();

    final void renderTerrainDisplacement(){
        if(needTerrainDisplacement()){
            terrainMaterialBackend.bindDisplacement();
            displaceTerrain();
            terrainMaterialBackend.unbindDisplacement();
        }
    }

    override void onRender()
    {
        static if(gbuffers.length!=1){
            scope(success){
                curGBuffer=(curGBuffer+1)%gbuffers.length;
                deferredEnvPass.gbuffer=gbuffer;
                deferredLightPass.gbuffer=gbuffer;
            }
        }
        renderTerrainDisplacement();
        renderShadows(&rc3d);
        gbuffer.render(&rc3d);
        sceneFramebuffer.bind();

        RenderingContext rcDeferred;
        rcDeferred.initOrtho(width, height, environment, width, height, 0.0f, 100.0f);
        prepareViewport();
        sceneFramebuffer.clearBuffers();

        glBindFramebuffer(GL_READ_FRAMEBUFFER, gbuffer.fbo);
        glBlitFramebuffer(0, 0, gbuffer.width, gbuffer.height, 0, 0, gbuffer.width, gbuffer.height, GL_DEPTH_BUFFER_BIT, GL_NEAREST);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);

        renderBackgroundEntities3D(&rc3d);
        deferredEnvPass.render(&rcDeferred, &rc3d);
        deferredLightPass.render(&rcDeferred, &rc3d);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT6, GL_TEXTURE_2D, gbuffer.informationTexture, 0);
        GLenum[7] bufs = [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_NONE, GL_NONE, GL_NONE, GL_NONE, GL_COLOR_ATTACHMENT6];
        glDrawBuffers(bufs.length, bufs.ptr);
        renderTransparentEntities3D(&rc3d);
        particleSystem.render(&rc3d);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT6, GL_TEXTURE_2D, 0, 0);

        sceneFramebuffer.unbind();

        if (hdrFilter.autoExposure)
        {
            sceneFramebuffer.genLuminanceMipmaps();
            float lum = sceneFramebuffer.averageLuminance();
            if (!isNaN(lum))
            {
                float newExposure = hdrFilter.keyValue * (1.0f / clamp(lum, hdrFilter.minLuminance, hdrFilter.maxLuminance));

                float exposureDelta = newExposure - hdrFilter.exposure;
                hdrFilter.exposure += exposureDelta * hdrFilter.adaptationSpeed * /+eventManager.deltaTime+/1.0f/60.0f;
            }
        }

        if (hdrPrepassFilter.glowEnabled)
            renderBlur(glow.radius);

        RenderingContext rcTmp;
        Framebuffer nextInput = sceneFramebuffer;

        hdrPrepassFilter.perspectiveMatrix = rc3d.projectionMatrix;

        foreach(i, f; postFilters.data)
        if (f.enabled)
        {
            if (f.outputBuffer is null)
                f.outputBuffer = New!Framebuffer(width, height, false, false, assetManager);

            if (f.inputBuffer is null)
                f.inputBuffer = nextInput;

            nextInput = f.outputBuffer;

            f.outputBuffer.bind();
            rcTmp.initOrtho(width, height, environment, f.outputBuffer.width, f.outputBuffer.height, 0.0f, 100.0f);
            prepareViewport(f.outputBuffer);
            f.render(&rcTmp);
            f.outputBuffer.unbind();
        }

        glScissor(0, 0, eventManager.windowWidth, eventManager.windowHeight);
        glViewport(0, 0, eventManager.windowWidth, eventManager.windowHeight);
        glClearColor(0.0f,0.0f,0.0f,1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        prepareViewport(null, true);
        finalizerFilter.inputBuffer = nextInput;
        finalizerFilter.render(&rc2d);

        startGBufferInformationDownload();

        renderEntities2D(&rc2d);
    }
}

alias Scene BaseScene3D;
