// SPDX-License-Identifier: MIT
/* d3d11bench.exe: D3D11 flip-model swapchain + full-window pixel shader loop (same math as vkbench).
 * Usage: d3d11bench.exe [seconds=10] [iters=16] [width=1280] [height=720] [sync=0]
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_4.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char hlsl[] =
	"cbuffer C : register(b0) { float t; int iters; float2 pad; };\n"
	"struct V { float4 pos : SV_Position; float2 uv : TEXCOORD0; };\n"
	"V vs(uint id : SV_VertexID) { V o; float2 p = float2((id << 1) & 2, id & 2); o.uv = p;\n"
	"  o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o; }\n"
	"float4 ps(V i) : SV_Target { float2 p = i.uv; float3 c = 0;\n"
	"  for (int k = 0; k < iters; k++) { p = frac(p * 1.37 + sin(p.yx * 3.1 + t)); c += float3(p, p.x * p.y) * 0.02; }\n"
	"  return float4(frac(c + float3(i.uv, 0.5)), 1.0); }\n";

static volatile int quit;
static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
	if (m == WM_CLOSE || m == WM_DESTROY || (m == WM_KEYDOWN && w == VK_ESCAPE)) { quit = 1; return 0; }
	return DefWindowProcA(h, m, w, l);
}
static double now(void)
{
	static LARGE_INTEGER f; LARGE_INTEGER c;
	if (!f.QuadPart) QueryPerformanceFrequency(&f);
	QueryPerformanceCounter(&c);
	return (double)c.QuadPart / (double)f.QuadPart;
}
#define CK(x) do { HRESULT h_ = (x); if (FAILED(h_)) { printf("FAIL %s -> 0x%08lx (line %d)\n", #x, (unsigned long)h_, __LINE__); ExitProcess(1); } } while (0)

typedef HRESULT (WINAPI *PFN_D3DCompile)(const void *, SIZE_T, const char *, const D3D_SHADER_MACRO *, ID3DInclude *, const char *, const char *, UINT, UINT, ID3DBlob **, ID3DBlob **);

int main(int argc, char **argv)
{
	int seconds = argc > 1 ? atoi(argv[1]) : 10, iters = argc > 2 ? atoi(argv[2]) : 16;
	int W = argc > 3 ? atoi(argv[3]) : 1280, H = argc > 4 ? atoi(argv[4]) : 720, sync = argc > 5 ? atoi(argv[5]) : 0;
	setvbuf(stdout, NULL, _IONBF, 0);

	WNDCLASSA wc = {CS_OWNDC, wndproc, 0, 0, GetModuleHandleA(NULL), NULL, LoadCursor(NULL, IDC_ARROW), NULL, NULL, "d3d11bench"};
	RegisterClassA(&wc);
	RECT rc = {0, 0, W, H}; AdjustWindowRect(&rc, WS_OVERLAPPEDWINDOW, FALSE);
	HWND hwnd = CreateWindowA("d3d11bench", "d3d11bench", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40, rc.right - rc.left, rc.bottom - rc.top, NULL, NULL, wc.hInstance, NULL);
	MSG msg; while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }

	IDXGIFactory2 *fac; CK(CreateDXGIFactory1(&IID_IDXGIFactory2, (void **)&fac));
	IDXGIAdapter1 *ad; CK(IDXGIFactory2_EnumAdapters1(fac, 0, &ad));
	DXGI_ADAPTER_DESC1 desc; IDXGIAdapter1_GetDesc1(ad, &desc);
	printf("adapter: %ls | %04x:%04x | VRAM %llu MB\n", desc.Description, desc.VendorId, desc.DeviceId, (unsigned long long)desc.DedicatedVideoMemory >> 20);

	ID3D11Device *dev; ID3D11DeviceContext *ctx; D3D_FEATURE_LEVEL fl, fls[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
	CK(D3D11CreateDevice((IDXGIAdapter *)ad, D3D_DRIVER_TYPE_UNKNOWN, NULL, 0, fls, 2, D3D11_SDK_VERSION, &dev, &fl, &ctx));
	printf("feature level 0x%x\n", fl);

	DXGI_SWAP_CHAIN_DESC1 sd = {W, H, DXGI_FORMAT_B8G8R8A8_UNORM, FALSE, {1, 0}, DXGI_USAGE_RENDER_TARGET_OUTPUT, 3,
		DXGI_SCALING_STRETCH, DXGI_SWAP_EFFECT_FLIP_DISCARD, DXGI_ALPHA_MODE_UNSPECIFIED, DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING};
	IDXGISwapChain1 *sc; CK(IDXGIFactory2_CreateSwapChainForHwnd(fac, (IUnknown *)dev, hwnd, &sd, NULL, NULL, &sc));
	ID3D11Texture2D *bb; CK(IDXGISwapChain1_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb));
	ID3D11RenderTargetView *rtv; CK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv));

	HMODULE dc = LoadLibraryA("d3dcompiler_47.dll");
	PFN_D3DCompile comp = (PFN_D3DCompile)(void *)GetProcAddress(dc, "D3DCompile");
	ID3DBlob *vsb, *psb, *err = NULL;
	if (FAILED(comp(hlsl, sizeof(hlsl) - 1, "b", NULL, NULL, "vs", "vs_5_0", 0, 0, &vsb, &err))) { printf("vs: %s\n", err ? (char *)ID3D10Blob_GetBufferPointer(err) : "?"); return 1; }
	if (FAILED(comp(hlsl, sizeof(hlsl) - 1, "b", NULL, NULL, "ps", "ps_5_0", 0, 0, &psb, &err))) { printf("ps: %s\n", err ? (char *)ID3D10Blob_GetBufferPointer(err) : "?"); return 1; }
	ID3D11VertexShader *vs; ID3D11PixelShader *ps;
	CK(ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(vsb), ID3D10Blob_GetBufferSize(vsb), NULL, &vs));
	CK(ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(psb), ID3D10Blob_GetBufferSize(psb), NULL, &ps));
	D3D11_BUFFER_DESC cbd = {16, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0};
	ID3D11Buffer *cb; CK(ID3D11Device_CreateBuffer(dev, &cbd, NULL, &cb));
	/* the full-window triangle is counter-clockwise in D3D's y-up clip space: D3D11's default rasterizer state
	 * (CULL_BACK, FrontCounterClockwise FALSE) would cull it, so disable culling like the D3D12 and Vulkan benches */
	D3D11_RASTERIZER_DESC rsd = {D3D11_FILL_SOLID, D3D11_CULL_NONE, FALSE, 0, 0.0f, 0.0f, TRUE, FALSE, FALSE, FALSE};
	ID3D11RasterizerState *rs; CK(ID3D11Device_CreateRasterizerState(dev, &rsd, &rs));
	ID3D11DeviceContext_RSSetState(ctx, rs);
	D3D11_VIEWPORT vp = {0, 0, (float)W, (float)H, 0, 1};

	if (argc > 6 && !strcmp(argv[6], "check")) {
		/* correctness probe: draw into a 64x64 offscreen target with several loop counts, read the centre pixel back */
		D3D11_TEXTURE2D_DESC td = {64, 64, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET, 0, 0};
		ID3D11Texture2D *off, *stg; ID3D11RenderTargetView *orv;
		CK(ID3D11Device_CreateTexture2D(dev, &td, NULL, &off));
		td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
		CK(ID3D11Device_CreateTexture2D(dev, &td, NULL, &stg));
		CK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)off, NULL, &orv));
		D3D11_VIEWPORT ov = {0, 0, 64, 64, 0, 1};
		{
			/* 1: clear only -> tests ClearRenderTargetView + CopyResource + staging Map */
			const float cc[4] = {0.25f, 0.5f, 0.75f, 1.0f};
			ID3D11DeviceContext_ClearRenderTargetView(ctx, orv, cc);
			ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)stg, (ID3D11Resource *)off);
			D3D11_MAPPED_SUBRESOURCE m;
			CK(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)stg, 0, D3D11_MAP_READ, 0, &m));
			unsigned char *px = (unsigned char *)m.pData + 32 * m.RowPitch + 32 * 4;
			printf("CHECK clear(64,128,191,255) -> %u %u %u %u (rowpitch %u)\n", px[0], px[1], px[2], px[3], m.RowPitch);
			ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)stg, 0);
			/* 2: UpdateSubresource on the staging-less default texture */
			unsigned int pat[64 * 64]; for (int i = 0; i < 64 * 64; i++) pat[i] = 0x11223344u;
			ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)off, 0, NULL, pat, 64 * 4, 0);
			ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)stg, (ID3D11Resource *)off);
			CK(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)stg, 0, D3D11_MAP_READ, 0, &m));
			px = (unsigned char *)m.pData + 32 * m.RowPitch + 32 * 4;
			printf("CHECK upload(44 33 22 11) -> %02x %02x %02x %02x\n", px[0], px[1], px[2], px[3]);
			ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)stg, 0);
		}
		int its[] = {0, 1, 2, 5, 64};
		for (int k = 0; k < 5; k++) {
			D3D11_MAPPED_SUBRESOURCE m;
			CK(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m));
			struct { float t; int it; float pad[2]; } c = {0.25f, its[k], {0, 0}};
			memcpy(m.pData, &c, sizeof(c));
			ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)cb, 0);
			ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &orv, NULL);
			ID3D11DeviceContext_RSSetViewports(ctx, 1, &ov);
			ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
			ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
			ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
			ID3D11DeviceContext_PSSetConstantBuffers(ctx, 0, 1, &cb);
			ID3D11DeviceContext_Draw(ctx, 3, 0);
			ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)stg, (ID3D11Resource *)off);
			CK(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)stg, 0, D3D11_MAP_READ, 0, &m));
			unsigned char *px = (unsigned char *)m.pData + 32 * m.RowPitch + 32 * 4;
			unsigned char *p0 = (unsigned char *)m.pData + 5 * m.RowPitch + 7 * 4;
			printf("CHECK iters=%d centre rgba %u %u %u %u | (7,5) %u %u %u %u\n", its[k], px[0], px[1], px[2], px[3], p0[0], p0[1], p0[2], p0[3]);
			ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)stg, 0);
		}
		return 0;
	}
	double t0 = now(), tl = t0, best = 0, sum = 0; long frames = 0, flast = 0; int nsec = 0;
	while (!quit && now() - t0 < seconds) {
		while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
		D3D11_MAPPED_SUBRESOURCE m;
		CK(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m));
		struct { float t; int it; float pad[2]; } c = {(float)(now() - t0), iters, {0, 0}};
		memcpy(m.pData, &c, sizeof(c));
		ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)cb, 0);
		ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
		ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
		ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
		ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
		ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
		ID3D11DeviceContext_PSSetConstantBuffers(ctx, 0, 1, &cb);
		ID3D11DeviceContext_Draw(ctx, 3, 0);
		HRESULT hr = IDXGISwapChain1_Present(sc, sync, sync ? 0 : DXGI_PRESENT_ALLOW_TEARING);
		if (FAILED(hr)) { printf("Present -> 0x%08lx\n", (unsigned long)hr); break; }
		frames++;
		double t = now();
		if (t - tl >= 1.0) {
			double fps = (frames - flast) / (t - tl);
			printf("fps %.1f\n", fps);
			if (nsec > 0) { sum += fps; if (fps > best) best = fps; }
			nsec++; tl = t; flast = frames;
		}
	}
	printf("RESULT d3d11 iters=%d %dx%d sync=%d avg_fps=%.1f (steady %d s) best=%.1f frames=%ld\n", iters, W, H, sync,
	       nsec > 1 ? sum / (nsec - 1) : 0.0, nsec > 1 ? nsec - 1 : 0, best, frames);
	return 0;
}
