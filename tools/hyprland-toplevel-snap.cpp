#include <errno.h>
#include <fcntl.h>
#include <png.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>

#include "hyprland-toplevel-export-v1.hpp"

struct app_state {
    struct wl_display*                    display;
    struct wl_registry*                   registry;
    struct wl_shm*                        shm;
    CCHyprlandToplevelExportManagerV1*    manager;
    CCHyprlandToplevelExportFrameV1*      frame;
    struct wl_shm_pool*                   pool;
    struct wl_buffer*                     wl_buffer;
    uint8_t*                              pixels;
    size_t                                pixel_bytes;
    uint32_t                              handle32;
    bool                                  overlay_cursor;
    bool                                  done;
    bool                                  success;
    bool                                  y_invert;
    uint32_t                              format;
    uint32_t                              width;
    uint32_t                              height;
    uint32_t                              stride;
    char                                  error[256];
};

static void usage(FILE* out) {
    fprintf(out,
            "Usage: hyprland-toplevel-snap --address <addr> [--output <file>] [--cursor]\n"
            "\n"
            "Capture one Hyprland toplevel window to PNG.\n"
            "By default writes PNG bytes to stdout.\n"
            "\n"
            "Examples:\n"
            "  hyprland-toplevel-snap --address 0x5608f355bab0 > frame.png\n"
            "  hyprland-toplevel-snap --address 5608f355bab0 --output frame.png\n");
}

static int create_shm_file(size_t size) {
    int fd = memfd_create("hyprland-toplevel-snap", MFD_CLOEXEC);
    if (fd < 0) {
        char name[128];
        snprintf(name, sizeof(name), "/hyprland-toplevel-snap-%d-%ld", getpid(), random());
        fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
        if (fd >= 0)
            shm_unlink(name);
    }
    if (fd < 0)
        return -1;
    if (ftruncate(fd, (off_t)size) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static bool parse_handle(const char* input, uint32_t* out) {
    if (!input || !out || *input == '\0')
        return false;

    const char* s = input;
    int         base;

    if (strncmp(s, "0x", 2) == 0 || strncmp(s, "0X", 2) == 0) {
        s += 2;
        base = 16;
    } else if (strpbrk(s, "abcdefABCDEF") != NULL) {
        base = 16;
    } else {
        base = 10;
    }

    errno = 0;
    char*              end = NULL;
    unsigned long long v   = strtoull(s, &end, base);
    if (errno != 0 || !end || *end != '\0')
        return false;

    *out = (uint32_t)(v & 0xFFFFFFFFu);
    return true;
}

static void fail(struct app_state* app, const char* msg) {
    app->done    = true;
    app->success = false;
    snprintf(app->error, sizeof(app->error), "%s", msg ? msg : "unknown error");
}

static void on_frame_buffer(struct app_state* app, uint32_t format, uint32_t width, uint32_t height, uint32_t stride) {
    app->format = format;
    app->width  = width;
    app->height = height;
    app->stride = stride;
}

static void on_frame_flags(struct app_state* app, hyprlandToplevelExportFrameV1Flags flags) {
    app->y_invert = (flags & HYPRLAND_TOPLEVEL_EXPORT_FRAME_V1_FLAGS_Y_INVERT) != 0;
}

static void on_frame_ready(struct app_state* app) {
    app->done    = true;
    app->success = true;
}

static void on_frame_failed(struct app_state* app) {
    fail(app, "frame copy failed");
}

static void on_frame_buffer_done(struct app_state* app) {
    if (app->width == 0 || app->height == 0 || app->stride == 0) {
        fail(app, "missing wl_shm buffer metadata");
        return;
    }

    if (app->wl_buffer)
        return;

    app->pixel_bytes = (size_t)app->stride * (size_t)app->height;
    int fd           = create_shm_file(app->pixel_bytes);
    if (fd < 0) {
        fail(app, "failed to allocate shm file");
        return;
    }

    app->pixels = (uint8_t*)mmap(NULL, app->pixel_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (app->pixels == MAP_FAILED) {
        app->pixels = NULL;
        close(fd);
        fail(app, "failed to mmap shm buffer");
        return;
    }

    app->pool = wl_shm_create_pool(app->shm, fd, (int)app->pixel_bytes);
    close(fd);
    if (!app->pool) {
        fail(app, "failed to create wl_shm pool");
        return;
    }

    app->wl_buffer = wl_shm_pool_create_buffer(app->pool, 0, (int32_t)app->width, (int32_t)app->height,
                                               (int32_t)app->stride, app->format);
    if (!app->wl_buffer) {
        fail(app, "failed to create wl_buffer");
        return;
    }

    app->frame->sendCopy((wl_proxy*)app->wl_buffer, 1);
}

static void registry_global(void* data, struct wl_registry* registry, uint32_t name, const char* interface, uint32_t version) {
    struct app_state* app = (struct app_state*)data;
    if (strcmp(interface, wl_shm_interface.name) == 0) {
        app->shm = (wl_shm*)wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, hyprland_toplevel_export_manager_v1_interface.name) == 0) {
        uint32_t bind_version = version < 2 ? version : 2;
        wl_proxy* proxy       = (wl_proxy*)wl_registry_bind(registry, name, &hyprland_toplevel_export_manager_v1_interface, bind_version);
        app->manager          = new CCHyprlandToplevelExportManagerV1(proxy);
    }
}

static void registry_global_remove(void* data, struct wl_registry* registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global        = registry_global,
    .global_remove = registry_global_remove,
};

static bool write_png(const struct app_state* app, const char* output_path, char* err, size_t errlen) {
    FILE* out = stdout;
    if (output_path) {
        out = fopen(output_path, "wb");
        if (!out) {
            snprintf(err, errlen, "failed to open output file: %s", output_path);
            return false;
        }
    }

    png_structp png_ptr = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png_ptr) {
        if (output_path)
            fclose(out);
        snprintf(err, errlen, "failed to create png struct");
        return false;
    }

    png_infop info_ptr = png_create_info_struct(png_ptr);
    if (!info_ptr) {
        png_destroy_write_struct(&png_ptr, NULL);
        if (output_path)
            fclose(out);
        snprintf(err, errlen, "failed to create png info struct");
        return false;
    }

    if (setjmp(png_jmpbuf(png_ptr))) {
        png_destroy_write_struct(&png_ptr, &info_ptr);
        if (output_path)
            fclose(out);
        snprintf(err, errlen, "libpng write error");
        return false;
    }

    png_init_io(png_ptr, out);
    png_set_IHDR(png_ptr, info_ptr, app->width, app->height, 8, PNG_COLOR_TYPE_RGBA, PNG_INTERLACE_NONE,
                 PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    png_write_info(png_ptr, info_ptr);

    uint8_t* row_rgba = (uint8_t*)malloc((size_t)app->width * 4u);
    if (!row_rgba) {
        png_destroy_write_struct(&png_ptr, &info_ptr);
        if (output_path)
            fclose(out);
        snprintf(err, errlen, "failed to allocate row buffer");
        return false;
    }

    for (uint32_t y = 0; y < app->height; ++y) {
        uint32_t        src_y  = app->y_invert ? (app->height - 1u - y) : y;
        const uint8_t*  srcrow = app->pixels + ((size_t)src_y * app->stride);
        const uint32_t* src32  = (const uint32_t*)srcrow;

        for (uint32_t x = 0; x < app->width; ++x) {
            uint32_t p = src32[x];
            uint8_t  r, g, b, a;
            switch (app->format) {
                case WL_SHM_FORMAT_ARGB8888:
                    a = (uint8_t)((p >> 24) & 0xFFu);
                    r = (uint8_t)((p >> 16) & 0xFFu);
                    g = (uint8_t)((p >> 8) & 0xFFu);
                    b = (uint8_t)(p & 0xFFu);
                    break;
                case WL_SHM_FORMAT_XRGB8888:
                    a = 0xFFu;
                    r = (uint8_t)((p >> 16) & 0xFFu);
                    g = (uint8_t)((p >> 8) & 0xFFu);
                    b = (uint8_t)(p & 0xFFu);
                    break;
#ifdef WL_SHM_FORMAT_ABGR8888
                case WL_SHM_FORMAT_ABGR8888:
                    a = (uint8_t)((p >> 24) & 0xFFu);
                    b = (uint8_t)((p >> 16) & 0xFFu);
                    g = (uint8_t)((p >> 8) & 0xFFu);
                    r = (uint8_t)(p & 0xFFu);
                    break;
#endif
#ifdef WL_SHM_FORMAT_XBGR8888
                case WL_SHM_FORMAT_XBGR8888:
                    a = 0xFFu;
                    b = (uint8_t)((p >> 16) & 0xFFu);
                    g = (uint8_t)((p >> 8) & 0xFFu);
                    r = (uint8_t)(p & 0xFFu);
                    break;
#endif
                default:
                    free(row_rgba);
                    png_destroy_write_struct(&png_ptr, &info_ptr);
                    if (output_path)
                        fclose(out);
                    snprintf(err, errlen, "unsupported wl_shm format: %u", app->format);
                    return false;
            }
            row_rgba[4u * x + 0u] = r;
            row_rgba[4u * x + 1u] = g;
            row_rgba[4u * x + 2u] = b;
            row_rgba[4u * x + 3u] = a;
        }
        png_write_row(png_ptr, row_rgba);
    }

    free(row_rgba);
    png_write_end(png_ptr, info_ptr);
    png_destroy_write_struct(&png_ptr, &info_ptr);
    if (output_path)
        fclose(out);
    return true;
}

static void app_cleanup(struct app_state* app) {
    if (app->frame) {
        delete app->frame;
        app->frame = NULL;
    }
    if (app->wl_buffer) {
        wl_buffer_destroy(app->wl_buffer);
        app->wl_buffer = NULL;
    }
    if (app->pool) {
        wl_shm_pool_destroy(app->pool);
        app->pool = NULL;
    }
    if (app->manager) {
        delete app->manager;
        app->manager = NULL;
    }
    if (app->shm) {
        wl_shm_destroy(app->shm);
        app->shm = NULL;
    }
    if (app->registry) {
        wl_registry_destroy(app->registry);
        app->registry = NULL;
    }
    if (app->display) {
        wl_display_disconnect(app->display);
        app->display = NULL;
    }
    if (app->pixels) {
        munmap(app->pixels, app->pixel_bytes);
        app->pixels = NULL;
    }
}

int main(int argc, char** argv) {
    struct app_state app = {};
    const char*      output_path = NULL;

    srandom((unsigned int)time(NULL));

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(stdout);
            return 0;
        }
        if (strcmp(argv[i], "--address") == 0 && i + 1 < argc) {
            if (!parse_handle(argv[++i], &app.handle32)) {
                fprintf(stderr, "Invalid --address: %s\n", argv[i]);
                return 2;
            }
            continue;
        }
        if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
            output_path = argv[++i];
            continue;
        }
        if (strcmp(argv[i], "--cursor") == 0) {
            app.overlay_cursor = true;
            continue;
        }
        fprintf(stderr, "Unknown argument: %s\n", argv[i]);
        usage(stderr);
        return 2;
    }

    if (app.handle32 == 0u) {
        fprintf(stderr, "--address is required\n");
        usage(stderr);
        return 2;
    }

    app.display = wl_display_connect(NULL);
    if (!app.display) {
        fprintf(stderr, "Failed to connect to Wayland display\n");
        return 1;
    }

    app.registry = wl_display_get_registry(app.display);
    wl_registry_add_listener(app.registry, &registry_listener, &app);
    wl_display_roundtrip(app.display);

    if (!app.shm || !app.manager) {
        fprintf(stderr, "Required globals missing (wl_shm or hyprland toplevel export manager)\n");
        app_cleanup(&app);
        return 1;
    }

    wl_proxy* frame_proxy = app.manager->sendCaptureToplevel(app.overlay_cursor ? 1 : 0, app.handle32);
    if (!frame_proxy) {
        fprintf(stderr, "Failed to create export frame\n");
        app_cleanup(&app);
        return 1;
    }

    app.frame = new CCHyprlandToplevelExportFrameV1(frame_proxy);
    app.frame->setBuffer([&app](CCHyprlandToplevelExportFrameV1*, uint32_t format, uint32_t width, uint32_t height, uint32_t stride) {
        on_frame_buffer(&app, format, width, height, stride);
    });
    app.frame->setDamage([](CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t, uint32_t) {});
    app.frame->setFlags([&app](CCHyprlandToplevelExportFrameV1*, hyprlandToplevelExportFrameV1Flags flags) {
        on_frame_flags(&app, flags);
    });
    app.frame->setReady([&app](CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t) {
        on_frame_ready(&app);
    });
    app.frame->setFailed([&app](CCHyprlandToplevelExportFrameV1*) {
        on_frame_failed(&app);
    });
    app.frame->setLinuxDmabuf([](CCHyprlandToplevelExportFrameV1*, uint32_t, uint32_t, uint32_t) {});
    app.frame->setBufferDone([&app](CCHyprlandToplevelExportFrameV1*) {
        on_frame_buffer_done(&app);
    });

    while (!app.done) {
        if (wl_display_dispatch(app.display) < 0) {
            fail(&app, "Wayland dispatch failed");
            break;
        }
    }

    int exit_code = 0;
    if (!app.success) {
        fprintf(stderr, "Capture failed: %s\n", app.error[0] ? app.error : "unknown error");
        exit_code = 1;
    } else {
        char err[256] = {0};
        if (!write_png(&app, output_path, err, sizeof(err))) {
            fprintf(stderr, "PNG write failed: %s\n", err[0] ? err : "unknown");
            exit_code = 1;
        }
    }

    app_cleanup(&app);
    return exit_code;
}
