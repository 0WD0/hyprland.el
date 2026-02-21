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

#define private public
#define HYPRWAYLAND_SCANNER_NO_INTERFACES
#include "hyprland-toplevel-export-v1.hpp"
#undef private
#define F std::function

static const wl_interface* hyprlandToplevelExportV1_dummyTypes[] = { nullptr };

// Reference all other interfaces.
// The reason why this is in snake is to
// be able to cooperate with existing
// wayland_scanner interfaces (they are interop)
extern const wl_interface hyprland_toplevel_export_manager_v1_interface;
extern const wl_interface hyprland_toplevel_export_frame_v1_interface;
extern const wl_interface zwlr_foreign_toplevel_handle_v1_interface;
extern const wl_interface wl_buffer_interface;

static const void* _CCHyprlandToplevelExportManagerV1VTable[] = {
    nullptr,
};

wl_proxy* CCHyprlandToplevelExportManagerV1::sendCaptureToplevel(int32_t overlay_cursor, uint32_t handle) {
    if (!pResource)
        return nullptr;

    auto proxy = wl_proxy_marshal_flags(pResource, 0, &hyprland_toplevel_export_frame_v1_interface, wl_proxy_get_version(pResource), 0, nullptr, overlay_cursor, handle);

    return proxy;
}

void CCHyprlandToplevelExportManagerV1::sendDestroy() {
    if (!pResource)
        return;
    destroyed = true;

    auto proxy = wl_proxy_marshal_flags(pResource, 1, nullptr, wl_proxy_get_version(pResource), 1);
    proxy;
}

wl_proxy* CCHyprlandToplevelExportManagerV1::sendCaptureToplevelWithWlrToplevelHandle(int32_t overlay_cursor, wl_proxy* handle) {
    if (!pResource)
        return nullptr;

    auto proxy = wl_proxy_marshal_flags(pResource, 2, &hyprland_toplevel_export_frame_v1_interface, wl_proxy_get_version(pResource), 0, nullptr, overlay_cursor, handle);

    return proxy;
}
static const wl_interface* _CHyprlandToplevelExportManagerV1CaptureToplevelTypes[] = {
    &hyprland_toplevel_export_frame_v1_interface,
    nullptr,
    nullptr,
};
static const wl_interface* _CHyprlandToplevelExportManagerV1CaptureToplevelWithWlrToplevelHandleTypes[] = {
    &hyprland_toplevel_export_frame_v1_interface,
    nullptr,
    &zwlr_foreign_toplevel_handle_v1_interface,
};

static const wl_message _CHyprlandToplevelExportManagerV1Requests[] = {
    { .name = "capture_toplevel", .signature = "niu", .types = _CHyprlandToplevelExportManagerV1CaptureToplevelTypes + 0},
    { .name = "destroy", .signature = "", .types = hyprlandToplevelExportV1_dummyTypes + 0},
    { .name = "capture_toplevel_with_wlr_toplevel_handle", .signature = "2nio", .types = _CHyprlandToplevelExportManagerV1CaptureToplevelWithWlrToplevelHandleTypes + 0},
};

const wl_interface hyprland_toplevel_export_manager_v1_interface = {
    .name = "hyprland_toplevel_export_manager_v1", .version = 2,
    .method_count = 3, .methods = _CHyprlandToplevelExportManagerV1Requests,
    .event_count = 0, .events = nullptr,
};

CCHyprlandToplevelExportManagerV1::CCHyprlandToplevelExportManagerV1(wl_proxy* resource) : pResource(resource) {

    if (!pResource)
        return;

    wl_proxy_add_listener(pResource, (void (**)(void))&_CCHyprlandToplevelExportManagerV1VTable, this);
}

CCHyprlandToplevelExportManagerV1::~CCHyprlandToplevelExportManagerV1() {
    if (!destroyed)
        sendDestroy();
}

static void _CHyprlandToplevelExportFrameV1Buffer(void* data, void* resource, uint32_t format, uint32_t width, uint32_t height, uint32_t stride) {
    const auto PO = (CCHyprlandToplevelExportFrameV1*)data;
    if (PO && PO->requests.buffer)
        PO->requests.buffer(PO, format, width, height, stride);
}

static void _CHyprlandToplevelExportFrameV1Damage(void* data, void* resource, uint32_t x, uint32_t y, uint32_t width, uint32_t height) {
    const auto PO = (CCHyprlandToplevelExportFrameV1*)data;
    if (PO && PO->requests.damage)
        PO->requests.damage(PO, x, y, width, height);
}

static void _CHyprlandToplevelExportFrameV1Flags(void* data, void* resource, hyprlandToplevelExportFrameV1Flags flags) {
    const auto PO = (CCHyprlandToplevelExportFrameV1*)data;
    if (PO && PO->requests.flags)
        PO->requests.flags(PO, flags);
}

static void _CHyprlandToplevelExportFrameV1Ready(void* data, void* resource, uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec) {
    const auto PO = (CCHyprlandToplevelExportFrameV1*)data;
    if (PO && PO->requests.ready)
        PO->requests.ready(PO, tv_sec_hi, tv_sec_lo, tv_nsec);
}

static void _CHyprlandToplevelExportFrameV1Failed(void* data, void* resource) {
    const auto PO = (CCHyprlandToplevelExportFrameV1*)data;
    if (PO && PO->requests.failed)
        PO->requests.failed(PO);
}

static void _CHyprlandToplevelExportFrameV1LinuxDmabuf(void* data, void* resource, uint32_t format, uint32_t width, uint32_t height) {
    const auto PO = (CCHyprlandToplevelExportFrameV1*)data;
    if (PO && PO->requests.linuxDmabuf)
        PO->requests.linuxDmabuf(PO, format, width, height);
}

static void _CHyprlandToplevelExportFrameV1BufferDone(void* data, void* resource) {
    const auto PO = (CCHyprlandToplevelExportFrameV1*)data;
    if (PO && PO->requests.bufferDone)
        PO->requests.bufferDone(PO);
}

static const void* _CCHyprlandToplevelExportFrameV1VTable[] = {
    (void*)_CHyprlandToplevelExportFrameV1Buffer,
    (void*)_CHyprlandToplevelExportFrameV1Damage,
    (void*)_CHyprlandToplevelExportFrameV1Flags,
    (void*)_CHyprlandToplevelExportFrameV1Ready,
    (void*)_CHyprlandToplevelExportFrameV1Failed,
    (void*)_CHyprlandToplevelExportFrameV1LinuxDmabuf,
    (void*)_CHyprlandToplevelExportFrameV1BufferDone,
};

void CCHyprlandToplevelExportFrameV1::sendCopy(wl_proxy* buffer, int32_t ignore_damage) {
    if (!pResource)
        return;

    auto proxy = wl_proxy_marshal_flags(pResource, 0, nullptr, wl_proxy_get_version(pResource), 0, buffer, ignore_damage);
    proxy;
}

void CCHyprlandToplevelExportFrameV1::sendDestroy() {
    if (!pResource)
        return;
    destroyed = true;

    auto proxy = wl_proxy_marshal_flags(pResource, 1, nullptr, wl_proxy_get_version(pResource), 1);
    proxy;
}
static const wl_interface* _CHyprlandToplevelExportFrameV1CopyTypes[] = {
    &wl_buffer_interface,
    nullptr,
};
static const wl_interface* _CHyprlandToplevelExportFrameV1BufferTypes[] = {
    nullptr,
    nullptr,
    nullptr,
    nullptr,
};
static const wl_interface* _CHyprlandToplevelExportFrameV1DamageTypes[] = {
    nullptr,
    nullptr,
    nullptr,
    nullptr,
};
static const wl_interface* _CHyprlandToplevelExportFrameV1FlagsTypes[] = {
    nullptr,
};
static const wl_interface* _CHyprlandToplevelExportFrameV1ReadyTypes[] = {
    nullptr,
    nullptr,
    nullptr,
};
static const wl_interface* _CHyprlandToplevelExportFrameV1LinuxDmabufTypes[] = {
    nullptr,
    nullptr,
    nullptr,
};

static const wl_message _CHyprlandToplevelExportFrameV1Requests[] = {
    { .name = "copy", .signature = "oi", .types = _CHyprlandToplevelExportFrameV1CopyTypes + 0},
    { .name = "destroy", .signature = "", .types = hyprlandToplevelExportV1_dummyTypes + 0},
};

static const wl_message _CHyprlandToplevelExportFrameV1Events[] = {
    { .name = "buffer", .signature = "uuuu", .types = _CHyprlandToplevelExportFrameV1BufferTypes + 0},
    { .name = "damage", .signature = "uuuu", .types = _CHyprlandToplevelExportFrameV1DamageTypes + 0},
    { .name = "flags", .signature = "u", .types = _CHyprlandToplevelExportFrameV1FlagsTypes + 0},
    { .name = "ready", .signature = "uuu", .types = _CHyprlandToplevelExportFrameV1ReadyTypes + 0},
    { .name = "failed", .signature = "", .types = hyprlandToplevelExportV1_dummyTypes + 0},
    { .name = "linux_dmabuf", .signature = "uuu", .types = _CHyprlandToplevelExportFrameV1LinuxDmabufTypes + 0},
    { .name = "buffer_done", .signature = "", .types = hyprlandToplevelExportV1_dummyTypes + 0},
};

const wl_interface hyprland_toplevel_export_frame_v1_interface = {
    .name = "hyprland_toplevel_export_frame_v1", .version = 2,
    .method_count = 2, .methods = _CHyprlandToplevelExportFrameV1Requests,
    .event_count = 7, .events = _CHyprlandToplevelExportFrameV1Events,
};

CCHyprlandToplevelExportFrameV1::CCHyprlandToplevelExportFrameV1(wl_proxy* resource) : pResource(resource) {

    if (!pResource)
        return;

    wl_proxy_add_listener(pResource, (void (**)(void))&_CCHyprlandToplevelExportFrameV1VTable, this);
}

CCHyprlandToplevelExportFrameV1::~CCHyprlandToplevelExportFrameV1() {
    if (!destroyed)
        sendDestroy();
}

void CCHyprlandToplevelExportFrameV1::setBuffer(F<void(CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t, uint32_t)> &&handler) {
    requests.buffer = std::move(handler);
}

void CCHyprlandToplevelExportFrameV1::setDamage(F<void(CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t, uint32_t)> &&handler) {
    requests.damage = std::move(handler);
}

void CCHyprlandToplevelExportFrameV1::setFlags(F<void(CCHyprlandToplevelExportFrameV1*, hyprlandToplevelExportFrameV1Flags)> &&handler) {
    requests.flags = std::move(handler);
}

void CCHyprlandToplevelExportFrameV1::setReady(F<void(CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t)> &&handler) {
    requests.ready = std::move(handler);
}

void CCHyprlandToplevelExportFrameV1::setFailed(F<void(CCHyprlandToplevelExportFrameV1*)> &&handler) {
    requests.failed = std::move(handler);
}

void CCHyprlandToplevelExportFrameV1::setLinuxDmabuf(F<void(CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t)> &&handler) {
    requests.linuxDmabuf = std::move(handler);
}

void CCHyprlandToplevelExportFrameV1::setBufferDone(F<void(CCHyprlandToplevelExportFrameV1*)> &&handler) {
    requests.bufferDone = std::move(handler);
}

#undef F
