// Generated with hyprwayland-scanner 0.4.5. Made with vaxry's keyboard and ❤️.
// wlr_foreign_toplevel_management_unstable_v1

/*
 This protocol's authors' copyright notice is:


    Copyright © 2018 Ilia Bozhinov

    Permission to use, copy, modify, distribute, and sell this
    software and its documentation for any purpose is hereby granted
    without fee, provided that the above copyright notice appear in
    all copies and that both that copyright notice and this permission
    notice appear in supporting documentation, and that the name of
    the copyright holders not be used in advertising or publicity
    pertaining to distribution of the software without specific,
    written prior permission.  The copyright holders make no
    representations about the suitability of this software for any
    purpose.  It is provided "as is" without express or implied
    warranty.

    THE COPYRIGHT HOLDERS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS
    SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
    FITNESS, IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
    SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
    WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
    AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
    ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
    THIS SOFTWARE.
  
*/

#pragma once

#include <functional>
#include <cstdint>
#include <string>
#include <wayland-client.h>

#define F std::function

struct wl_proxy;

enum zwlrForeignToplevelHandleV1State : uint32_t {
    ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED = 0,
    ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED = 1,
    ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED = 2,
    ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN = 3,
};

enum zwlrForeignToplevelHandleV1Error : uint32_t {
    ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_ERROR_INVALID_RECTANGLE = 0,
};


class CCZwlrForeignToplevelManagerV1;
class CCZwlrForeignToplevelHandleV1;
class CCZwlrForeignToplevelHandleV1;
class CCWlSeat;
class CCWlSurface;
class CCWlOutput;
class CCWlOutput;
class CCWlOutput;
class CCZwlrForeignToplevelHandleV1;

#ifndef HYPRWAYLAND_SCANNER_NO_INTERFACES
extern const wl_interface zwlr_foreign_toplevel_manager_v1_interface;
extern const wl_interface zwlr_foreign_toplevel_handle_v1_interface;

#endif


class CCZwlrForeignToplevelManagerV1 {
  public:
    CCZwlrForeignToplevelManagerV1(wl_proxy*);
    ~CCZwlrForeignToplevelManagerV1();


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

    void setToplevel(F<void(CCZwlrForeignToplevelManagerV1*, wl_proxy*)> &&handler);
    void setFinished(F<void(CCZwlrForeignToplevelManagerV1*)> &&handler);

    // --------------- Events --------------- //

    void sendStop();

  private:
    struct {
        F<void(CCZwlrForeignToplevelManagerV1*, wl_proxy*)> toplevel;
        F<void(CCZwlrForeignToplevelManagerV1*)> finished;
    } requests;

    wl_proxy* pResource = nullptr;

    bool destroyed = false;

    void* pData = nullptr;
};



class CCZwlrForeignToplevelHandleV1 {
  public:
    CCZwlrForeignToplevelHandleV1(wl_proxy*);
    ~CCZwlrForeignToplevelHandleV1();


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

    void setTitle(F<void(CCZwlrForeignToplevelHandleV1*, const char*)> &&handler);
    void setAppId(F<void(CCZwlrForeignToplevelHandleV1*, const char*)> &&handler);
    void setOutputEnter(F<void(CCZwlrForeignToplevelHandleV1*, wl_proxy*)> &&handler);
    void setOutputLeave(F<void(CCZwlrForeignToplevelHandleV1*, wl_proxy*)> &&handler);
    void setState(F<void(CCZwlrForeignToplevelHandleV1*, wl_array*)> &&handler);
    void setDone(F<void(CCZwlrForeignToplevelHandleV1*)> &&handler);
    void setClosed(F<void(CCZwlrForeignToplevelHandleV1*)> &&handler);
    void setParent(F<void(CCZwlrForeignToplevelHandleV1*, wl_proxy*)> &&handler);

    // --------------- Events --------------- //

    void sendSetMaximized();
    void sendUnsetMaximized();
    void sendSetMinimized();
    void sendUnsetMinimized();
    void sendActivate(wl_proxy*);
    void sendClose();
    void sendSetRectangle(wl_proxy*, int32_t, int32_t, int32_t, int32_t);
    void sendDestroy();
    void sendSetFullscreen(wl_proxy*);
    void sendUnsetFullscreen();

  private:
    struct {
        F<void(CCZwlrForeignToplevelHandleV1*, const char*)> title;
        F<void(CCZwlrForeignToplevelHandleV1*, const char*)> appId;
        F<void(CCZwlrForeignToplevelHandleV1*, wl_proxy*)> outputEnter;
        F<void(CCZwlrForeignToplevelHandleV1*, wl_proxy*)> outputLeave;
        F<void(CCZwlrForeignToplevelHandleV1*, wl_array*)> state;
        F<void(CCZwlrForeignToplevelHandleV1*)> done;
        F<void(CCZwlrForeignToplevelHandleV1*)> closed;
        F<void(CCZwlrForeignToplevelHandleV1*, wl_proxy*)> parent;
    } requests;

    wl_proxy* pResource = nullptr;

    bool destroyed = false;

    void* pData = nullptr;
};



#undef F
