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

#define private public
#define HYPRWAYLAND_SCANNER_NO_INTERFACES
#include "wlr-foreign-toplevel-management-unstable-v1.hpp"
#undef private
#define F std::function

static const wl_interface* wlrForeignToplevelManagementUnstableV1_dummyTypes[] = { nullptr };

// Reference all other interfaces.
// The reason why this is in snake is to
// be able to cooperate with existing
// wayland_scanner interfaces (they are interop)
extern const wl_interface zwlr_foreign_toplevel_manager_v1_interface;
extern const wl_interface zwlr_foreign_toplevel_handle_v1_interface;
extern const wl_interface wl_seat_interface;
extern const wl_interface wl_surface_interface;
extern const wl_interface wl_output_interface;

static void _CZwlrForeignToplevelManagerV1Toplevel(void* data, void* resource, wl_proxy* toplevel) {
    const auto PO = (CCZwlrForeignToplevelManagerV1*)data;
    if (PO && PO->requests.toplevel)
        PO->requests.toplevel(PO, toplevel);
}

static void _CZwlrForeignToplevelManagerV1Finished(void* data, void* resource) {
    const auto PO = (CCZwlrForeignToplevelManagerV1*)data;
    if (PO && PO->requests.finished)
        PO->requests.finished(PO);
}

static const void* _CCZwlrForeignToplevelManagerV1VTable[] = {
    (void*)_CZwlrForeignToplevelManagerV1Toplevel,
    (void*)_CZwlrForeignToplevelManagerV1Finished,
};

void CCZwlrForeignToplevelManagerV1::sendStop() {
    if (!pResource)
        return;

    auto proxy = wl_proxy_marshal_flags(pResource, 0, nullptr, wl_proxy_get_version(pResource), 0);
    proxy;
}
static const wl_interface* _CZwlrForeignToplevelManagerV1ToplevelTypes[] = {
    &zwlr_foreign_toplevel_handle_v1_interface,
};

static const wl_message _CZwlrForeignToplevelManagerV1Requests[] = {
    { .name = "stop", .signature = "", .types = wlrForeignToplevelManagementUnstableV1_dummyTypes + 0},
};

static const wl_message _CZwlrForeignToplevelManagerV1Events[] = {
    { .name = "toplevel", .signature = "n", .types = _CZwlrForeignToplevelManagerV1ToplevelTypes + 0},
    { .name = "finished", .signature = "", .types = wlrForeignToplevelManagementUnstableV1_dummyTypes + 0},
};

const wl_interface zwlr_foreign_toplevel_manager_v1_interface = {
    .name = "zwlr_foreign_toplevel_manager_v1", .version = 3,
    .method_count = 1, .methods = _CZwlrForeignToplevelManagerV1Requests,
    .event_count = 2, .events = _CZwlrForeignToplevelManagerV1Events,
};

CCZwlrForeignToplevelManagerV1::CCZwlrForeignToplevelManagerV1(wl_proxy* resource) : pResource(resource) {

    if (!pResource)
        return;

    wl_proxy_add_listener(pResource, (void (**)(void))&_CCZwlrForeignToplevelManagerV1VTable, this);
}

CCZwlrForeignToplevelManagerV1::~CCZwlrForeignToplevelManagerV1() {
    if (!destroyed)
        wl_proxy_destroy(pResource);
}

void CCZwlrForeignToplevelManagerV1::setToplevel(F<void(CCZwlrForeignToplevelManagerV1*, wl_proxy*)> &&handler) {
    requests.toplevel = std::move(handler);
}

void CCZwlrForeignToplevelManagerV1::setFinished(F<void(CCZwlrForeignToplevelManagerV1*)> &&handler) {
    requests.finished = std::move(handler);
}

static void _CZwlrForeignToplevelHandleV1Title(void* data, void* resource, const char* title) {
    const auto PO = (CCZwlrForeignToplevelHandleV1*)data;
    if (PO && PO->requests.title)
        PO->requests.title(PO, title);
}

static void _CZwlrForeignToplevelHandleV1AppId(void* data, void* resource, const char* app_id) {
    const auto PO = (CCZwlrForeignToplevelHandleV1*)data;
    if (PO && PO->requests.appId)
        PO->requests.appId(PO, app_id);
}

static void _CZwlrForeignToplevelHandleV1OutputEnter(void* data, void* resource, wl_proxy* output) {
    const auto PO = (CCZwlrForeignToplevelHandleV1*)data;
    if (PO && PO->requests.outputEnter)
        PO->requests.outputEnter(PO, output);
}

static void _CZwlrForeignToplevelHandleV1OutputLeave(void* data, void* resource, wl_proxy* output) {
    const auto PO = (CCZwlrForeignToplevelHandleV1*)data;
    if (PO && PO->requests.outputLeave)
        PO->requests.outputLeave(PO, output);
}

static void _CZwlrForeignToplevelHandleV1State(void* data, void* resource, wl_array* state) {
    const auto PO = (CCZwlrForeignToplevelHandleV1*)data;
    if (PO && PO->requests.state)
        PO->requests.state(PO, state);
}

static void _CZwlrForeignToplevelHandleV1Done(void* data, void* resource) {
    const auto PO = (CCZwlrForeignToplevelHandleV1*)data;
    if (PO && PO->requests.done)
        PO->requests.done(PO);
}

static void _CZwlrForeignToplevelHandleV1Closed(void* data, void* resource) {
    const auto PO = (CCZwlrForeignToplevelHandleV1*)data;
    if (PO && PO->requests.closed)
        PO->requests.closed(PO);
}

static void _CZwlrForeignToplevelHandleV1Parent(void* data, void* resource, wl_proxy* parent) {
    const auto PO = (CCZwlrForeignToplevelHandleV1*)data;
    if (PO && PO->requests.parent)
        PO->requests.parent(PO, parent);
}

static const void* _CCZwlrForeignToplevelHandleV1VTable[] = {
    (void*)_CZwlrForeignToplevelHandleV1Title,
    (void*)_CZwlrForeignToplevelHandleV1AppId,
    (void*)_CZwlrForeignToplevelHandleV1OutputEnter,
    (void*)_CZwlrForeignToplevelHandleV1OutputLeave,
    (void*)_CZwlrForeignToplevelHandleV1State,
    (void*)_CZwlrForeignToplevelHandleV1Done,
    (void*)_CZwlrForeignToplevelHandleV1Closed,
    (void*)_CZwlrForeignToplevelHandleV1Parent,
};

void CCZwlrForeignToplevelHandleV1::sendSetMaximized() {
    if (!pResource)
        return;

    auto proxy = wl_proxy_marshal_flags(pResource, 0, nullptr, wl_proxy_get_version(pResource), 0);
    proxy;
}

void CCZwlrForeignToplevelHandleV1::sendUnsetMaximized() {
    if (!pResource)
        return;

    auto proxy = wl_proxy_marshal_flags(pResource, 1, nullptr, wl_proxy_get_version(pResource), 0);
    proxy;
}

void CCZwlrForeignToplevelHandleV1::sendSetMinimized() {
    if (!pResource)
        return;

    auto proxy = wl_proxy_marshal_flags(pResource, 2, nullptr, wl_proxy_get_version(pResource), 0);
    proxy;
}

void CCZwlrForeignToplevelHandleV1::sendUnsetMinimized() {
    if (!pResource)
        return;

    auto proxy = wl_proxy_marshal_flags(pResource, 3, nullptr, wl_proxy_get_version(pResource), 0);
    proxy;
}

void CCZwlrForeignToplevelHandleV1::sendActivate(wl_proxy* seat) {
    if (!pResource)
        return;

    auto proxy = wl_proxy_marshal_flags(pResource, 4, nullptr, wl_proxy_get_version(pResource), 0, seat);
    proxy;
}

void CCZwlrForeignToplevelHandleV1::sendClose() {
    if (!pResource)
        return;

    auto proxy = wl_proxy_marshal_flags(pResource, 5, nullptr, wl_proxy_get_version(pResource), 0);
    proxy;
}

void CCZwlrForeignToplevelHandleV1::sendSetRectangle(wl_proxy* surface, int32_t x, int32_t y, int32_t width, int32_t height) {
    if (!pResource)
        return;

    auto proxy = wl_proxy_marshal_flags(pResource, 6, nullptr, wl_proxy_get_version(pResource), 0, surface, x, y, width, height);
    proxy;
}

void CCZwlrForeignToplevelHandleV1::sendDestroy() {
    if (!pResource)
        return;
    destroyed = true;

    auto proxy = wl_proxy_marshal_flags(pResource, 7, nullptr, wl_proxy_get_version(pResource), 1);
    proxy;
}

void CCZwlrForeignToplevelHandleV1::sendSetFullscreen(wl_proxy* output) {
    if (!pResource)
        return;

    auto proxy = wl_proxy_marshal_flags(pResource, 8, nullptr, wl_proxy_get_version(pResource), 0, output);
    proxy;
}

void CCZwlrForeignToplevelHandleV1::sendUnsetFullscreen() {
    if (!pResource)
        return;

    auto proxy = wl_proxy_marshal_flags(pResource, 9, nullptr, wl_proxy_get_version(pResource), 0);
    proxy;
}
static const wl_interface* _CZwlrForeignToplevelHandleV1ActivateTypes[] = {
    &wl_seat_interface,
};
static const wl_interface* _CZwlrForeignToplevelHandleV1SetRectangleTypes[] = {
    &wl_surface_interface,
    nullptr,
    nullptr,
    nullptr,
    nullptr,
};
static const wl_interface* _CZwlrForeignToplevelHandleV1SetFullscreenTypes[] = {
    &wl_output_interface,
};
static const wl_interface* _CZwlrForeignToplevelHandleV1TitleTypes[] = {
    nullptr,
};
static const wl_interface* _CZwlrForeignToplevelHandleV1AppIdTypes[] = {
    nullptr,
};
static const wl_interface* _CZwlrForeignToplevelHandleV1OutputEnterTypes[] = {
    &wl_output_interface,
};
static const wl_interface* _CZwlrForeignToplevelHandleV1OutputLeaveTypes[] = {
    &wl_output_interface,
};
static const wl_interface* _CZwlrForeignToplevelHandleV1StateTypes[] = {
    nullptr,
};
static const wl_interface* _CZwlrForeignToplevelHandleV1ParentTypes[] = {
    &zwlr_foreign_toplevel_handle_v1_interface,
};

static const wl_message _CZwlrForeignToplevelHandleV1Requests[] = {
    { .name = "set_maximized", .signature = "", .types = wlrForeignToplevelManagementUnstableV1_dummyTypes + 0},
    { .name = "unset_maximized", .signature = "", .types = wlrForeignToplevelManagementUnstableV1_dummyTypes + 0},
    { .name = "set_minimized", .signature = "", .types = wlrForeignToplevelManagementUnstableV1_dummyTypes + 0},
    { .name = "unset_minimized", .signature = "", .types = wlrForeignToplevelManagementUnstableV1_dummyTypes + 0},
    { .name = "activate", .signature = "o", .types = _CZwlrForeignToplevelHandleV1ActivateTypes + 0},
    { .name = "close", .signature = "", .types = wlrForeignToplevelManagementUnstableV1_dummyTypes + 0},
    { .name = "set_rectangle", .signature = "oiiii", .types = _CZwlrForeignToplevelHandleV1SetRectangleTypes + 0},
    { .name = "destroy", .signature = "", .types = wlrForeignToplevelManagementUnstableV1_dummyTypes + 0},
    { .name = "set_fullscreen", .signature = "2?o", .types = _CZwlrForeignToplevelHandleV1SetFullscreenTypes + 0},
    { .name = "unset_fullscreen", .signature = "2", .types = wlrForeignToplevelManagementUnstableV1_dummyTypes + 0},
};

static const wl_message _CZwlrForeignToplevelHandleV1Events[] = {
    { .name = "title", .signature = "s", .types = _CZwlrForeignToplevelHandleV1TitleTypes + 0},
    { .name = "app_id", .signature = "s", .types = _CZwlrForeignToplevelHandleV1AppIdTypes + 0},
    { .name = "output_enter", .signature = "o", .types = _CZwlrForeignToplevelHandleV1OutputEnterTypes + 0},
    { .name = "output_leave", .signature = "o", .types = _CZwlrForeignToplevelHandleV1OutputLeaveTypes + 0},
    { .name = "state", .signature = "a", .types = _CZwlrForeignToplevelHandleV1StateTypes + 0},
    { .name = "done", .signature = "", .types = wlrForeignToplevelManagementUnstableV1_dummyTypes + 0},
    { .name = "closed", .signature = "", .types = wlrForeignToplevelManagementUnstableV1_dummyTypes + 0},
    { .name = "parent", .signature = "3?o", .types = _CZwlrForeignToplevelHandleV1ParentTypes + 0},
};

const wl_interface zwlr_foreign_toplevel_handle_v1_interface = {
    .name = "zwlr_foreign_toplevel_handle_v1", .version = 3,
    .method_count = 10, .methods = _CZwlrForeignToplevelHandleV1Requests,
    .event_count = 8, .events = _CZwlrForeignToplevelHandleV1Events,
};

CCZwlrForeignToplevelHandleV1::CCZwlrForeignToplevelHandleV1(wl_proxy* resource) : pResource(resource) {

    if (!pResource)
        return;

    wl_proxy_add_listener(pResource, (void (**)(void))&_CCZwlrForeignToplevelHandleV1VTable, this);
}

CCZwlrForeignToplevelHandleV1::~CCZwlrForeignToplevelHandleV1() {
    if (!destroyed)
        sendDestroy();
}

void CCZwlrForeignToplevelHandleV1::setTitle(F<void(CCZwlrForeignToplevelHandleV1*, const char*)> &&handler) {
    requests.title = std::move(handler);
}

void CCZwlrForeignToplevelHandleV1::setAppId(F<void(CCZwlrForeignToplevelHandleV1*, const char*)> &&handler) {
    requests.appId = std::move(handler);
}

void CCZwlrForeignToplevelHandleV1::setOutputEnter(F<void(CCZwlrForeignToplevelHandleV1*, wl_proxy*)> &&handler) {
    requests.outputEnter = std::move(handler);
}

void CCZwlrForeignToplevelHandleV1::setOutputLeave(F<void(CCZwlrForeignToplevelHandleV1*, wl_proxy*)> &&handler) {
    requests.outputLeave = std::move(handler);
}

void CCZwlrForeignToplevelHandleV1::setState(F<void(CCZwlrForeignToplevelHandleV1*, wl_array*)> &&handler) {
    requests.state = std::move(handler);
}

void CCZwlrForeignToplevelHandleV1::setDone(F<void(CCZwlrForeignToplevelHandleV1*)> &&handler) {
    requests.done = std::move(handler);
}

void CCZwlrForeignToplevelHandleV1::setClosed(F<void(CCZwlrForeignToplevelHandleV1*)> &&handler) {
    requests.closed = std::move(handler);
}

void CCZwlrForeignToplevelHandleV1::setParent(F<void(CCZwlrForeignToplevelHandleV1*, wl_proxy*)> &&handler) {
    requests.parent = std::move(handler);
}

#undef F
