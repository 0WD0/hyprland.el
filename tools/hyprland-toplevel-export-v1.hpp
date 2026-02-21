// Generated with hyprwayland-scanner 0.4.5. Made with vaxry's keyboard and ❤️.
// hyprland_toplevel_export_v1

/*
 This protocol's authors' copyright notice is:


    Copyright © 2022 Vaxry
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, this
       list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright notice,
       this list of conditions and the following disclaimer in the documentation
       and/or other materials provided with the distribution.

    3. Neither the name of the copyright holder nor the names of its
       contributors may be used to endorse or promote products derived from
       this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
    FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
    SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
    OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
  
*/

#pragma once

#include <functional>
#include <cstdint>
#include <string>
#include <wayland-client.h>

#define F std::function

struct wl_proxy;

enum hyprlandToplevelExportFrameV1Error : uint32_t {
    HYPRLAND_TOPLEVEL_EXPORT_FRAME_V1_ERROR_ALREADY_USED = 0,
    HYPRLAND_TOPLEVEL_EXPORT_FRAME_V1_ERROR_INVALID_BUFFER = 1,
};

enum hyprlandToplevelExportFrameV1Flags : uint32_t {
    HYPRLAND_TOPLEVEL_EXPORT_FRAME_V1_FLAGS_Y_INVERT = 1,
};


class CCHyprlandToplevelExportManagerV1;
class CCHyprlandToplevelExportFrameV1;
class CCHyprlandToplevelExportFrameV1;
class CCZwlrForeignToplevelHandleV1;
class CCHyprlandToplevelExportFrameV1;
class CCWlBuffer;

#ifndef HYPRWAYLAND_SCANNER_NO_INTERFACES
extern const wl_interface hyprland_toplevel_export_manager_v1_interface;
extern const wl_interface hyprland_toplevel_export_frame_v1_interface;

#endif


class CCHyprlandToplevelExportManagerV1 {
  public:
    CCHyprlandToplevelExportManagerV1(wl_proxy*);
    ~CCHyprlandToplevelExportManagerV1();


    // set the data for this resource
    void setData(void* data) {{
        pData = data;
    }}

    // get the data for this resource
    void* data() {{
        return pData;
    }}

    // get the raw wl_resource (wl_proxy) ptr
    wl_proxy* resource() {{
        return pResource;
    }}

    // get the raw wl_proxy ptr
    wl_proxy* proxy() {{
        return pResource;
    }}

    // get the resource version
    int version() {{
        return wl_proxy_get_version(pResource);
    }}
            
    // --------------- Requests --------------- //


    // --------------- Events --------------- //

    wl_proxy* sendCaptureToplevel(int32_t, uint32_t);
    void sendDestroy();
    wl_proxy* sendCaptureToplevelWithWlrToplevelHandle(int32_t, wl_proxy*);

  private:
    struct {
    } requests;

    wl_proxy* pResource = nullptr;

    bool destroyed = false;

    void* pData = nullptr;
};



class CCHyprlandToplevelExportFrameV1 {
  public:
    CCHyprlandToplevelExportFrameV1(wl_proxy*);
    ~CCHyprlandToplevelExportFrameV1();


    // set the data for this resource
    void setData(void* data) {{
        pData = data;
    }}

    // get the data for this resource
    void* data() {{
        return pData;
    }}

    // get the raw wl_resource (wl_proxy) ptr
    wl_proxy* resource() {{
        return pResource;
    }}

    // get the raw wl_proxy ptr
    wl_proxy* proxy() {{
        return pResource;
    }}

    // get the resource version
    int version() {{
        return wl_proxy_get_version(pResource);
    }}
            
    // --------------- Requests --------------- //

    void setBuffer(F<void(CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t, uint32_t)> &&handler);
    void setDamage(F<void(CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t, uint32_t)> &&handler);
    void setFlags(F<void(CCHyprlandToplevelExportFrameV1*, hyprlandToplevelExportFrameV1Flags)> &&handler);
    void setReady(F<void(CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t)> &&handler);
    void setFailed(F<void(CCHyprlandToplevelExportFrameV1*)> &&handler);
    void setLinuxDmabuf(F<void(CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t)> &&handler);
    void setBufferDone(F<void(CCHyprlandToplevelExportFrameV1*)> &&handler);

    // --------------- Events --------------- //

    void sendCopy(wl_proxy*, int32_t);
    void sendDestroy();

  private:
    struct {
        F<void(CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t, uint32_t)> buffer;
        F<void(CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t, uint32_t)> damage;
        F<void(CCHyprlandToplevelExportFrameV1*, hyprlandToplevelExportFrameV1Flags)> flags;
        F<void(CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t)> ready;
        F<void(CCHyprlandToplevelExportFrameV1*)> failed;
        F<void(CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t)> linuxDmabuf;
        F<void(CCHyprlandToplevelExportFrameV1*)> bufferDone;
    } requests;

    wl_proxy* pResource = nullptr;

    bool destroyed = false;

    void* pData = nullptr;
};



#undef F
