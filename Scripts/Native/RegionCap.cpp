/* RegionCap.dll
   Copies one client rectangle out of the window's DWM shared surface.
   Exports stay HC_Copy and HC_Last: AutoHotkey already calls those names.
   DwmGetDxSharedSurface is undocumented and lives in user32, not dwmapi. */
#define INITGUID
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <stdint.h>

typedef HRESULT (WINAPI *PFN_GetSurf)(HWND, HANDLE*, LUID*, ULONG*, ULONG*, ULONGLONG*);

static PFN_GetSurf pGetSurf = NULL;
static ID3D11Device* g_dev = NULL;
static ID3D11DeviceContext* g_ctx = NULL;
static ID3D11Texture2D* g_shared = NULL;
static ID3D11Texture2D* g_stage = NULL;
static HANDLE g_handle = NULL;
static LUID g_luid = {};
static int g_sw = 0, g_sh = 0;
static int g_last = 0;

static void drop_shared() {
    if (g_shared) { g_shared->Release(); g_shared = NULL; }
    g_handle = NULL;
}

static void drop_all() {
    drop_shared();
    if (g_stage) { g_stage->Release(); g_stage = NULL; }
    g_sw = g_sh = 0;
    if (g_ctx) { g_ctx->Release(); g_ctx = NULL; }
    if (g_dev) { g_dev->Release(); g_dev = NULL; }
}

static int ensure_device(LUID luid) {
    if (g_dev && g_luid.LowPart == luid.LowPart && g_luid.HighPart == luid.HighPart)
        return 1;
    drop_all();
    IDXGIFactory1* factory = NULL;
    if (FAILED(CreateDXGIFactory1(IID_IDXGIFactory1, (void**)&factory)))
        return 0;
    IDXGIAdapter1* adapter = NULL;
    IDXGIAdapter1* chosen = NULL;
    for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND; i++) {
        DXGI_ADAPTER_DESC1 desc;
        adapter->GetDesc1(&desc);
        if (desc.AdapterLuid.LowPart == luid.LowPart && desc.AdapterLuid.HighPart == luid.HighPart)
            chosen = adapter;
        else
            adapter->Release();
    }
    factory->Release();
    if (!chosen)
        return 0;
    D3D_FEATURE_LEVEL fl;
    HRESULT hr = D3D11CreateDevice(chosen, D3D_DRIVER_TYPE_UNKNOWN, NULL,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0, D3D11_SDK_VERSION,
        &g_dev, &fl, &g_ctx);
    chosen->Release();
    if (FAILED(hr))
        return 0;
    g_luid = luid;
    return 1;
}

extern "C" __declspec(dllexport)
int HC_Copy(HWND hwnd, int x, int y, int w, int h, void* dst, int dstStride) {
    g_last = 1;
    if (!hwnd || !dst || w < 2 || h < 2 || dstStride < w * 4)
        return 0;
    if (!pGetSurf) {
        pGetSurf = (PFN_GetSurf)GetProcAddress(GetModuleHandleA("user32.dll"), "DwmGetDxSharedSurface");
        if (!pGetSurf) { g_last = 2; return 0; }
    }
    HANDLE surface = NULL;
    LUID luid = {};
    ULONG fmt = 0, present = 0;
    ULONGLONG update = 0;
    if (!pGetSurf(hwnd, &surface, &luid, &fmt, &present, &update) || !surface) {
        g_last = 3; return 0;
    }
    if (!ensure_device(luid)) { g_last = 4; return 0; }
    if (surface != g_handle) {
        drop_shared();
        HRESULT hr = g_dev->OpenSharedResource(surface, IID_ID3D11Texture2D, (void**)&g_shared);
        if (FAILED(hr) || !g_shared) { g_last = 5; return 0; }
        g_handle = surface;
    }
    POINT origin = {0, 0};
    ClientToScreen(hwnd, &origin);
    RECT wr;
    GetWindowRect(hwnd, &wr);
    int sx = x + (origin.x - wr.left);
    int sy = y + (origin.y - wr.top);
    D3D11_TEXTURE2D_DESC td;
    g_shared->GetDesc(&td);
    if (sx < 0 || sy < 0 || sx + w > (int)td.Width || sy + h > (int)td.Height) {
        g_last = 6; return 0;
    }
    if (!g_stage || g_sw != w || g_sh != h) {
        if (g_stage) { g_stage->Release(); g_stage = NULL; }
        D3D11_TEXTURE2D_DESC sd = td;
        sd.Width = w; sd.Height = h; sd.MipLevels = 1; sd.ArraySize = 1;
        sd.SampleDesc.Count = 1; sd.SampleDesc.Quality = 0;
        sd.Usage = D3D11_USAGE_STAGING; sd.BindFlags = 0;
        sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ; sd.MiscFlags = 0;
        if (FAILED(g_dev->CreateTexture2D(&sd, NULL, &g_stage))) { g_last = 7; return 0; }
        g_sw = w; g_sh = h;
    }
    IDXGIKeyedMutex* mutex = NULL;
    g_shared->QueryInterface(IID_IDXGIKeyedMutex, (void**)&mutex);
    if (mutex) mutex->AcquireSync(0, 8);
    D3D11_BOX box;
    box.left = sx; box.top = sy; box.front = 0;
    box.right = sx + w; box.bottom = sy + h; box.back = 1;
    g_ctx->CopySubresourceRegion(g_stage, 0, 0, 0, 0, g_shared, 0, &box);
    if (mutex) { mutex->ReleaseSync(0); mutex->Release(); }
    D3D11_MAPPED_SUBRESOURCE map;
    if (FAILED(g_ctx->Map(g_stage, 0, D3D11_MAP_READ, 0, &map))) { g_last = 8; return 0; }
    const unsigned char* src = (const unsigned char*)map.pData;
    unsigned char* out = (unsigned char*)dst;
    for (int row = 0; row < h; row++)
        memcpy(out + row * dstStride, src + row * map.RowPitch, w * 4);
    g_ctx->Unmap(g_stage, 0);
    g_last = 0;
    return 1;
}

extern "C" __declspec(dllexport) int HC_Last() { return g_last; }
