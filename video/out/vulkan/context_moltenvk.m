/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <CoreGraphics/CoreGraphics.h>
#include <QuartzCore/CAMetalLayer.h>
#include <MoltenVK/mvk_vulkan.h>

#include "common.h"
#include "context.h"
#include "utils.h"

struct priv {
    struct mpvk_ctx vk;
    CAMetalLayer *layer;
    int last_width;
    int last_height;
};

// Use CAMetalLayer.drawableSize as source of truth (not vo->dwidth/dheight)
// because in embedded WinID scenarios, mpv doesn't know the real window size.
static bool resize(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    CGSize s = p->layer.drawableSize;
    int width = (int)s.width;
    int height = (int)s.height;

    if (width <= 0 || height <= 0)
        return false;

    // ALWAYS set vo dimensions first, before checking if swapchain needs resize.
    // This is critical because mpv's vo_reconfig overwrites them with video resolution.
    ctx->vo->dwidth = width;
    ctx->vo->dheight = height;

    if (width == p->last_width && height == p->last_height)
        return true;

    p->last_width = width;
    p->last_height = height;

    return ra_vk_ctx_resize(ctx, width, height);
}

static void moltenvk_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    ra_vk_ctx_uninit(ctx);
    mpvk_uninit(&p->vk);
}

static bool moltenvk_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    struct mpvk_ctx *vk = &p->vk;
    int msgl = ctx->opts.probing ? MSGL_V : MSGL_ERR;

    if (ctx->vo->opts->WinID == -1) {
        MP_MSG(ctx, msgl, "WinID missing\n");
        goto fail;
    }

    if (!mpvk_init(vk, ctx, VK_EXT_METAL_SURFACE_EXTENSION_NAME))
        goto fail;

    p->layer = (__bridge CAMetalLayer *)(intptr_t)ctx->vo->opts->WinID;

    VkMetalSurfaceCreateInfoEXT info = {
        .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
        .pLayer = p->layer,
    };

    VkInstance inst = vk->vkinst->instance;
    VkResult res = vkCreateMetalSurfaceEXT(inst, &info, NULL, &vk->surface);
    if (res != VK_SUCCESS) {
        MP_MSG(ctx, msgl, "Failed creating MoltenVK surface\n");
        goto fail;
    }

    if (!ra_vk_ctx_init(ctx, vk, (struct ra_ctx_params){0}, VK_PRESENT_MODE_FIFO_KHR))
        goto fail;

    // Force one initial resize from the layer size, if available.
    p->last_width = 0;
    p->last_height = 0;
    resize(ctx);

    return true;
fail:
    moltenvk_uninit(ctx);
    return false;
}

static bool moltenvk_reconfig(struct ra_ctx *ctx)
{
    return resize(ctx);
}

static int moltenvk_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    if (request != VOCTRL_CHECK_EVENTS)
        return VO_NOTIMPL;

    struct priv *p = ctx->priv;
    CGSize s = p->layer.drawableSize;
    int w = (int)s.width;
    int h = (int)s.height;

    if (w > 0 && h > 0 && (w != p->last_width || h != p->last_height)) {
        if (!resize(ctx))
            return VO_ERROR;
        *events |= VO_EVENT_RESIZE;
    }

    return VO_TRUE;
}

const struct ra_ctx_fns ra_ctx_vulkan_moltenvk = {
    .type     = "vulkan",
    .name     = "moltenvk",
    .reconfig = moltenvk_reconfig,
    .control  = moltenvk_control,
    .init     = moltenvk_init,
    .uninit   = moltenvk_uninit,
};
