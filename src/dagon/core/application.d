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

/++
    Base class to inherit Dagon applications from.
+/
module dagon.core.application;

import std.stdio;
import std.conv;
import std.getopt;
import std.string;
import std.file;
import core.stdc.stdlib;

import derelict.util.exception;
import derelict.sdl2.sdl;
import derelict.opengl;
import derelict.freetype.ft;

import dagon.core.event;

void exitWithError(string message)
{
    writeln(message);
    core.stdc.stdlib.exit(1);
}

enum DagonEvent
{
    Exit = -1
}

ShouldThrow ftOnMissingSymbol(string symbolName)
{
    writefln("Warning: failed to load Freetype function \"%s\"", symbolName);
    return ShouldThrow.No;
}

ShouldThrow sdlOnMissingSymbol(string symbolName)
{
    writefln("Warning: failed to load SDL2 function \"%s\"", symbolName);
    return ShouldThrow.No;
}

/++
    Base class to inherit Dagon applications from.
    `Application` wraps SDL2 window, loads dynamic link libraries using Derelict,
    is responsible for initializing OpenGL context and doing main game loop.
+/
class Application: EventListener
{
    uint width;
    uint height;
    SDL_Window* window = null;
    SDL_GLContext glcontext;
    string libdir;

    /++
        Constructor.
        * `winWidth` - window width
        * `winHeight` - window height
        * `fullscreen` - if true, the application will run in fullscreen mode
        * `windowTitle` - window title
        * `args` - command line arguments
    +/
    this(uint winWidth, uint winHeight, bool fullscreen, string windowTitle, string[] args)
    {
        try
        {
            getopt(
                args,
                "libdir", &libdir,
            );
        }
        catch(Exception)
        {
        }

        DerelictSDL2.missingSymbolCallback = &sdlOnMissingSymbol;
        DerelictFT.missingSymbolCallback = &ftOnMissingSymbol;

        DerelictGL3.load();
        if (libdir.length)
        {
            version(linux)
            {
                DerelictSDL2.load(format("%s/libSDL2-2.0.so", libdir));
                DerelictFT.load(format("%s/libfreetype.so", libdir));
            }
            version(Windows)
            {
                version(X86)
                {
                    DerelictSDL2.load(format("%s/SDL2.dll", libdir));
                    DerelictFT.load(format("%s/freetype281.dll", libdir));
                }
                version(X86_64)
                {
                    DerelictSDL2.load(format("%s/SDL2.dll", libdir));
                    DerelictFT.load(format("%s/freetype281.dll", libdir));
                }
            }
        }
        else
        {
            version(linux)
            {
                version(X86)
                {
                    if (exists("lib/x86/libSDL2-2.0.so"))
                        DerelictSDL2.load("lib/x86/libSDL2-2.0.so");
                    else
                        DerelictSDL2.load();

                    if (exists("lib/x86/libfreetype.so"))
                        DerelictFT.load("lib/x86/libfreetype.so");
                    else
                        DerelictFT.load();
                }
                version(X86_64)
                {
                    if (exists("lib/x64/libSDL2-2.0.so"))
                        DerelictSDL2.load("lib/x64/libSDL2-2.0.so");
                    else
                        DerelictSDL2.load();

                    if (exists("lib/x64/libfreetype.so"))
                        DerelictFT.load("lib/x64/libfreetype.so");
                    else
                        DerelictFT.load();
                }
            }
            version(Windows)
            {
                version(X86)
                {
                    if (exists("lib/x86/SDL2.dll"))
                        DerelictSDL2.load("lib/x86/SDL2.dll");
                    else
                        DerelictSDL2.load();

                    if (exists("lib/x86/freetype281.dll"))
                        DerelictFT.load("lib/x86/freetype281.dll");
                    else
                        DerelictFT.load();
                }
                version(X86_64)
                {
                    if (exists("lib/x64/SDL2.dll"))
                        DerelictSDL2.load("lib/x64/SDL2.dll");
                    else
                        DerelictSDL2.load();

                    if (exists("lib/x64/freetype281.dll"))
                        DerelictFT.load("lib/x64/freetype281.dll");
                    else
                        DerelictFT.load();
                }
            }
        }

        version(FreeBSD)
        {
            DerelictSDL2.load();
            DerelictFT.load();
        }

        if (SDL_Init(SDL_INIT_EVERYTHING) == -1)
            exitWithError("Failed to init SDL: " ~ to!string(SDL_GetError()));

        width = winWidth;
        height = winHeight;

        SDL_GL_SetAttribute(SDL_GL_ACCELERATED_VISUAL, 1);

        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 4);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG);
        SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
        SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
        SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);

        window = SDL_CreateWindow(toStringz(windowTitle),
            SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, width, height, SDL_WINDOW_SHOWN | SDL_WINDOW_OPENGL);
        if (window is null)
            exitWithError("Failed to create window: " ~ to!string(SDL_GetError()));

        SDL_GL_SetSwapInterval(1);

        glcontext = SDL_GL_CreateContext(window);
        if (glcontext is null)
            exitWithError("Failed to create GL context: " ~ to!string(SDL_GetError()));

        SDL_GL_MakeCurrent(window, glcontext);

        GLVersion loadedVersion = DerelictGL3.reload();
        writeln("OpenGL version loaded: ", loadedVersion);
        if (loadedVersion < GLVersion.gl40)
        {
            exitWithError("Sorry, Dagon requires OpenGL 4.0!");
        }

        if (fullscreen)
            SDL_SetWindowFullscreen(window, SDL_WINDOW_FULLSCREEN);

        EventManager eventManager = new EventManager(window, width, height);
        super(eventManager, null);

        // Initialize OpenGL
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClearDepth(1.0);
        glDepthFunc(GL_LESS);
        glEnable(GL_DEPTH_TEST);
        glEnable(GL_POLYGON_OFFSET_FILL);
        glCullFace(GL_BACK);

        //checkGLError();
    }

    override void onUserEvent(int code)
    {
        if (code == DagonEvent.Exit)
        {
            exit();
        }
    }

    void onUpdate(double dt)
    {
        // Override me
    }

    void onRender()
    {
        // Override me
    }

    void checkGLError()
    {
        GLenum error = GL_NO_ERROR;
        error = glGetError();
        if (error != GL_NO_ERROR)
        {
            writeln("OpenGL error: ", error);
            eventManager.running = false;
        }
    }

    void run()
    {
        while(eventManager.running)
        {
            beginRender();
            onRender();
            onUpdate(eventManager.deltaTime);
            endRender();
        }
    }

    void beginRender()
    {
        eventManager.update();
        processEvents();
    }

    void endRender()
    {
        debug checkGLError();
        SDL_GL_SwapWindow(window);
    }

    void exit()
    {
        eventManager.running = false;
    }

    ~this()
    {
        SDL_GL_DeleteContext(glcontext);
        SDL_DestroyWindow(window);
        SDL_Quit();
    }
}
