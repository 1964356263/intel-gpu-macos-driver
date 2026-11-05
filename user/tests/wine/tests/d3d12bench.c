// SPDX-License-Identifier: MIT
/* d3d12bench.exe: D3D12 flip-model swapchain + full-window pixel shader loop (same math as vkbench / d3d11bench).
 * Usage: d3d12bench.exe [seconds=10] [iters=16] [width=1280] [height=720] [sync=0]
 */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>

static const char hlsl[] =
	"cbuffer C : register(b0) { float t; int iters; };\n"
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

enum { NB = 3 };

int main(int argc, char **argv)
{
	int seconds = argc > 1 ? atoi(argv[1]) : 10, iters = argc > 2 ? atoi(argv[2]) : 16;
	int W = argc > 3 ? atoi(argv[3]) : 1280, H = argc > 4 ? atoi(argv[4]) : 720, sync = argc > 5 ? atoi(argv[5]) : 0;
	setvbuf(stdout, NULL, _IONBF, 0);

	WNDCLASSA wc = {CS_OWNDC, wndproc, 0, 0, GetModuleHandleA(NULL), NULL, LoadCursor(NULL, IDC_ARROW), NULL, NULL, "d3d12bench"};
	RegisterClassA(&wc);
	RECT rc = {0, 0, W, H}; AdjustWindowRect(&rc, WS_OVERLAPPEDWINDOW, FALSE);
	HWND hwnd = CreateWindowA("d3d12bench", "d3d12bench", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40, rc.right - rc.left, rc.bottom - rc.top, NULL, NULL, wc.hInstance, NULL);
	MSG msg; while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }

	IDXGIFactory4 *fac; CK(CreateDXGIFactory2(0, &IID_IDXGIFactory4, (void **)&fac));
	IDXGIAdapter1 *ad; CK(IDXGIFactory4_EnumAdapters1(fac, 0, &ad));
	DXGI_ADAPTER_DESC1 desc; IDXGIAdapter1_GetDesc1(ad, &desc);
	printf("adapter: %ls | %04x:%04x | VRAM %llu MB\n", desc.Description, desc.VendorId, desc.DeviceId, (unsigned long long)desc.DedicatedVideoMemory >> 20);

	ID3D12Device *dev; CK(D3D12CreateDevice((IUnknown *)ad, D3D_FEATURE_LEVEL_12_0, &IID_ID3D12Device, (void **)&dev));
	D3D12_FEATURE_DATA_D3D12_OPTIONS o = {0};
	ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS, &o, sizeof(o));
	D3D12_FEATURE_DATA_SHADER_MODEL sm = {D3D_SHADER_MODEL_6_7};
	ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_SHADER_MODEL, &sm, sizeof(sm));
	D3D12_FEATURE_DATA_D3D12_OPTIONS5 o5 = {0};
	ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS5, &o5, sizeof(o5));
	printf("resource binding tier %d, tiled tier %d, shader model 0x%x, raytracing tier %d\n", o.ResourceBindingTier, o.TiledResourcesTier, sm.HighestShaderModel, o5.RaytracingTier);

	D3D12_COMMAND_QUEUE_DESC qd = {D3D12_COMMAND_LIST_TYPE_DIRECT};
	ID3D12CommandQueue *q; CK(ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&q));
	DXGI_SWAP_CHAIN_DESC1 sd = {W, H, DXGI_FORMAT_B8G8R8A8_UNORM, FALSE, {1, 0}, DXGI_USAGE_RENDER_TARGET_OUTPUT, NB,
		DXGI_SCALING_STRETCH, DXGI_SWAP_EFFECT_FLIP_DISCARD, DXGI_ALPHA_MODE_UNSPECIFIED, DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING};
	IDXGISwapChain1 *sc1; CK(IDXGIFactory4_CreateSwapChainForHwnd(fac, (IUnknown *)q, hwnd, &sd, NULL, NULL, &sc1));
	IDXGISwapChain3 *sc; CK(IDXGISwapChain1_QueryInterface(sc1, &IID_IDXGISwapChain3, (void **)&sc));

	D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, NB, D3D12_DESCRIPTOR_HEAP_FLAG_NONE, 0};
	ID3D12DescriptorHeap *rtvh; CK(ID3D12Device_CreateDescriptorHeap(dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&rtvh));
	UINT rtvsz = ID3D12Device_GetDescriptorHandleIncrementSize(dev, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
	D3D12_CPU_DESCRIPTOR_HANDLE rtv0;
	rtv0 = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(rtvh);
	ID3D12Resource *bufs[NB];
	for (int i = 0; i < NB; i++) {
		CK(IDXGISwapChain3_GetBuffer(sc, i, &IID_ID3D12Resource, (void **)&bufs[i]));
		D3D12_CPU_DESCRIPTOR_HANDLE h = {rtv0.ptr + i * rtvsz};
		ID3D12Device_CreateRenderTargetView(dev, bufs[i], NULL, h);
	}

	D3D12_ROOT_PARAMETER rp = {D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS};
	rp.Constants.ShaderRegister = 0; rp.Constants.Num32BitValues = 2; rp.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
	D3D12_ROOT_SIGNATURE_DESC rsd = {1, &rp, 0, NULL, D3D12_ROOT_SIGNATURE_FLAG_NONE};
	ID3DBlob *rsb, *err = NULL;
	CK(D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &rsb, &err));
	ID3D12RootSignature *rs; CK(ID3D12Device_CreateRootSignature(dev, 0, ID3D10Blob_GetBufferPointer(rsb), ID3D10Blob_GetBufferSize(rsb), &IID_ID3D12RootSignature, (void **)&rs));

	HMODULE dc = LoadLibraryA("d3dcompiler_47.dll");
	PFN_D3DCompile comp = (PFN_D3DCompile)(void *)GetProcAddress(dc, "D3DCompile");
	ID3DBlob *vsb, *psb;
	if (FAILED(comp(hlsl, sizeof(hlsl) - 1, "b", NULL, NULL, "vs", "vs_5_0", 0, 0, &vsb, &err))) { printf("vs compile failed\n"); return 1; }
	if (FAILED(comp(hlsl, sizeof(hlsl) - 1, "b", NULL, NULL, "ps", "ps_5_0", 0, 0, &psb, &err))) { printf("ps compile failed\n"); return 1; }

	D3D12_GRAPHICS_PIPELINE_STATE_DESC pd = {0};
	pd.pRootSignature = rs;
	pd.VS.pShaderBytecode = ID3D10Blob_GetBufferPointer(vsb); pd.VS.BytecodeLength = ID3D10Blob_GetBufferSize(vsb);
	pd.PS.pShaderBytecode = ID3D10Blob_GetBufferPointer(psb); pd.PS.BytecodeLength = ID3D10Blob_GetBufferSize(psb);
	pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
	pd.SampleMask = UINT_MAX;
	pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID; pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE; pd.RasterizerState.DepthClipEnable = TRUE;
	pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
	pd.NumRenderTargets = 1; pd.RTVFormats[0] = DXGI_FORMAT_B8G8R8A8_UNORM; pd.SampleDesc.Count = 1;
	ID3D12PipelineState *pso; CK(ID3D12Device_CreateGraphicsPipelineState(dev, &pd, &IID_ID3D12PipelineState, (void **)&pso));

	ID3D12CommandAllocator *ca[NB]; ID3D12GraphicsCommandList *cl;
	for (int i = 0; i < NB; i++) CK(ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&ca[i]));
	CK(ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, ca[0], pso, &IID_ID3D12GraphicsCommandList, (void **)&cl));
	ID3D12GraphicsCommandList_Close(cl);
	ID3D12Fence *fence; CK(ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence));
	HANDLE ev = CreateEventA(NULL, FALSE, FALSE, NULL);
	UINT64 fv[NB] = {0}, next = 1;

	D3D12_VIEWPORT vp = {0, 0, (float)W, (float)H, 0, 1}; D3D12_RECT sr = {0, 0, W, H};
	double t0 = now(), tl = t0, best = 0, sum = 0; long frames = 0, flast = 0; int nsec = 0;
	while (!quit && now() - t0 < seconds) {
		while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
		UINT bi = IDXGISwapChain3_GetCurrentBackBufferIndex(sc);
		if (ID3D12Fence_GetCompletedValue(fence) < fv[bi]) { ID3D12Fence_SetEventOnCompletion(fence, fv[bi], ev); WaitForSingleObject(ev, INFINITE); }
		CK(ID3D12CommandAllocator_Reset(ca[bi]));
		CK(ID3D12GraphicsCommandList_Reset(cl, ca[bi], pso));
		D3D12_RESOURCE_BARRIER b = {D3D12_RESOURCE_BARRIER_TYPE_TRANSITION};
		b.Transition.pResource = bufs[bi]; b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
		b.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT; b.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
		ID3D12GraphicsCommandList_ResourceBarrier(cl, 1, &b);
		D3D12_CPU_DESCRIPTOR_HANDLE h = {rtv0.ptr + bi * rtvsz};
		ID3D12GraphicsCommandList_OMSetRenderTargets(cl, 1, &h, FALSE, NULL);
		ID3D12GraphicsCommandList_SetGraphicsRootSignature(cl, rs);
		struct { float t; int it; } c = {(float)(now() - t0), iters};
		ID3D12GraphicsCommandList_SetGraphicsRoot32BitConstants(cl, 0, 2, &c, 0);
		ID3D12GraphicsCommandList_RSSetViewports(cl, 1, &vp);
		ID3D12GraphicsCommandList_RSSetScissorRects(cl, 1, &sr);
		ID3D12GraphicsCommandList_IASetPrimitiveTopology(cl, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
		ID3D12GraphicsCommandList_DrawInstanced(cl, 3, 1, 0, 0);
		b.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET; b.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
		ID3D12GraphicsCommandList_ResourceBarrier(cl, 1, &b);
		CK(ID3D12GraphicsCommandList_Close(cl));
		ID3D12CommandList *lists[] = {(ID3D12CommandList *)cl};
		ID3D12CommandQueue_ExecuteCommandLists(q, 1, lists);
		HRESULT hr = IDXGISwapChain3_Present(sc, sync, sync ? 0 : DXGI_PRESENT_ALLOW_TEARING);
		if (FAILED(hr)) { printf("Present -> 0x%08lx\n", (unsigned long)hr); break; }
		fv[bi] = next; CK(ID3D12CommandQueue_Signal(q, fence, next++));
		frames++;
		double t = now();
		if (t - tl >= 1.0) {
			double fps = (frames - flast) / (t - tl);
			printf("fps %.1f\n", fps);
			if (nsec > 0) { sum += fps; if (fps > best) best = fps; }
			nsec++; tl = t; flast = frames;
		}
	}
	CK(ID3D12CommandQueue_Signal(q, fence, next));
	ID3D12Fence_SetEventOnCompletion(fence, next, ev); WaitForSingleObject(ev, 5000);
	printf("RESULT d3d12 iters=%d %dx%d sync=%d avg_fps=%.1f (steady %d s) best=%.1f frames=%ld\n", iters, W, H, sync,
	       nsec > 1 ? sum / (nsec - 1) : 0.0, nsec > 1 ? nsec - 1 : 0, best, frames);
	return 0;
}
