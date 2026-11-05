// SPDX-License-Identifier: MIT
// recover_unit.c: host-side unit test of the plugin's GPU reset recovery state machine (nullmoth/plugin/nvmtl_recover.h)
// against a mock of Mesa's nvmtl_anv_device_recover_v1. No GPU, no Metal: the generation logic (hang vs. victim), the
// one-recovery-per-loss rule under concurrent losers, the fence-waiter drain, the submit lock being held during the
// swap, the bounds (per-minute limit, failing Mesa), the timeout case and the NVMTL_FAKE_* parser.
//   build+run: tests/recover_unit.sh
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>
#include <time.h>

static int g_quiet;
void nvlog(const char *fmt, ...)
{
	if (g_quiet) return;
	va_list a; va_start(a, fmt); printf("    log: "); vprintf(fmt, a); printf("\n"); va_end(a);
}
static VkDevice g_dev = (VkDevice)(uintptr_t)0x1234;
static _Atomic int g_state = 1;
#include "../../../nullmoth/plugin/nvmtl_recover.h"
static pthread_mutex_t nvmtl_submit_mutex = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
static _Atomic uint64_t g_done_mask;   // bit s: nvmtl_sub_done(s) was called
static void nvmtl_sub_done(uint64_t s) { if (s && s < 64) atomic_fetch_or(&g_done_mask, 1ull << s); }

// ---- the mock Mesa entry point ----
static _Atomic int m_calls, m_fail_left, m_lost = 1, m_banned = 1, m_sleep_ms, m_waiters_seen = -1, m_lock_free = -1;
static _Atomic uint32_t m_flags;
static void *trylock_thread(void *p) {
	int r = pthread_mutex_trylock(&nvmtl_submit_mutex);
	if (!r) pthread_mutex_unlock(&nvmtl_submit_mutex);
	*(int *)p = r == 0;
	return NULL;
}
static VkResult mock_recover(VkDevice d, uint32_t flags, struct nvmtl_anv_recover_info *info)
{
	atomic_fetch_add(&m_calls, 1);
	atomic_store(&m_flags, flags);
	atomic_store(&m_waiters_seen, atomic_load(&g_fence_waiters));
	int free_ = -1; pthread_t t; pthread_create(&t, NULL, trylock_thread, &free_); pthread_join(t, NULL);
	atomic_store(&m_lock_free, free_);
	if (atomic_load(&m_sleep_ms)) usleep(1000 * atomic_load(&m_sleep_ms));
	if (d != g_dev || !info || info->size != sizeof *info) return VK_ERROR_INITIALIZATION_FAILED;
	if (atomic_load(&m_fail_left) > 0) { atomic_fetch_sub(&m_fail_left, 1); info->failed_step = 2; info->error = ENOMEM; return VK_ERROR_UNKNOWN; }
	info->was_lost = atomic_load(&m_lost) || (flags & NVMTL_ANV_RECOVER_FORCE);
	info->queues_banned = atomic_load(&m_banned);
	info->queues_replaced = info->was_lost ? 1 : 0;
	return VK_SUCCESS;
}

static int fails;
#define CHECK(cond, ...) do { if (cond) printf("  ok   " __VA_ARGS__); else { printf("  FAIL " __VA_ARGS__); fails++; } printf("\n"); } while (0)
static void reset_window(void) { g_recover_window_t0 = 0; g_recover_window_n = 0; }

typedef struct { unsigned gen; uint64_t seq; int r; } loser;
static void *lose_thread(void *p) { loser *l = p; l->r = nvmtl_vk_lost(l->seq, l->gen, 0, "unit", VK_ERROR_DEVICE_LOST); return NULL; }
static void *waiter_thread(void *p) {
	nvmtl_wait_enter(); usleep(1000 * *(int *)p); nvmtl_wait_leave(); return NULL;
}
static double now_ms(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6; }

int main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	unsetenv("NVMTL_RECOVER_MAX"); unsetenv("NVMTL_GPU_RECOVERY");

	printf("1. no Mesa entry point: the old behaviour\n");
	CHECK(nvmtl_vk_lost(1, 0, 0, "unit", VK_ERROR_DEVICE_LOST) == -2, "lost without nvmtl_anv_device_recover_v1 -> -2 (backend down)");
	CHECK(!(g_done_mask & 2), "its submission is not marked done");
	panv_recover = mock_recover;

	printf("2. one loss: the loser recovers (-3), the device generation moves, the submission is done\n");
	int r = nvmtl_vk_lost(2, 0, 0, "unit", VK_ERROR_DEVICE_LOST);
	CHECK(r == -3, "first loser -> %d (want -3, hang)", r);
	CHECK(atomic_load(&g_loss_gen) == 1, "generation %u (want 1)", atomic_load(&g_loss_gen));
	CHECK(g_done_mask & 4, "submission 2 marked done");
	CHECK(m_calls == 1 && m_flags == 0, "Mesa called once without FORCE (calls %d flags %u)", m_calls, m_flags);
	CHECK(m_lock_free == 0, "the submit lock was held during the queue swap");
	CHECK(g_state == 1, "backend still up");

	printf("3. an older submission seen lost afterwards is a victim, no second recovery\n");
	r = nvmtl_vk_lost(3, 0, 0, "unit", VK_ERROR_DEVICE_LOST);
	CHECK(r == -4 && m_calls == 1 && (g_done_mask & 8), "-> %d, Mesa calls %d (want -4, 1)", r, m_calls);

	printf("4. eight threads lose the same generation at once: one recovery\n");
	loser L[8]; pthread_t T[8];
	for (int i = 0; i < 8; i++) { L[i] = (loser){ 1, 10 + i, 0 }; pthread_create(&T[i], NULL, lose_thread, &L[i]); }
	int hang = 0, victim = 0;
	for (int i = 0; i < 8; i++) { pthread_join(T[i], NULL); hang += L[i].r == -3; victim += L[i].r == -4; }
	CHECK(hang == 1 && victim == 7 && m_calls == 2, "hang %d victim %d Mesa calls %d (want 1, 7, 2)", hang, victim, m_calls);
	CHECK(atomic_load(&g_loss_gen) == 2, "generation %u (want 2)", atomic_load(&g_loss_gen));
	reset_window();

	printf("5. fence waiters are drained before the swap, new ones wait for it\n");
	int hold = 300; pthread_t w; pthread_create(&w, NULL, waiter_thread, &hold);
	usleep(50000);
	atomic_store(&m_sleep_ms, 200);
	double t0 = now_ms();
	pthread_t w2; int hold2 = 1;
	loser l2 = { 2, 20, 0 }; pthread_t lt;
	pthread_create(&lt, NULL, lose_thread, &l2);
	usleep(100000);   // recovery is now draining (the first waiter still holds for ~150 ms)
	double tw = now_ms(); pthread_create(&w2, NULL, waiter_thread, &hold2);
	pthread_join(lt, NULL); double t1 = now_ms(); pthread_join(w2, NULL); double t2 = now_ms(); pthread_join(w, NULL);
	atomic_store(&m_sleep_ms, 0);
	CHECK(m_waiters_seen == 0, "no fence waiter inside the driver during the swap (saw %d)", m_waiters_seen);
	CHECK(t1 - t0 >= 240, "recovery waited for the waiter (%.0f ms)", t1 - t0);
	CHECK(t2 >= t1 - 5 && t2 - tw >= 100, "a waiter arriving during the recovery entered after it (%.0f ms after arriving)", t2 - tw);
	CHECK(l2.r == -3, "-> %d (want -3)", l2.r);

	printf("6. a stuck waiter does not block recovery for more than 2 s\n");
	hold = 4000; pthread_create(&w, NULL, waiter_thread, &hold); usleep(50000);
	t0 = now_ms(); r = nvmtl_vk_lost(21, 3, 0, "unit", VK_ERROR_DEVICE_LOST); t1 = now_ms();
	CHECK(r == -3 && t1 - t0 >= 1900 && t1 - t0 < 2600, "-> %d after %.0f ms (want -3 after ~2000)", r, t1 - t0);
	CHECK(m_waiters_seen == 1, "the swap went ahead with the stuck waiter (saw %d)", m_waiters_seen);
	pthread_join(w, NULL);
	reset_window();

	printf("7. a fence that gave up with nothing lost: only that command buffer fails (-5), not marked done\n");
	atomic_store(&m_lost, 0); atomic_store(&m_banned, 0);
	unsigned g = atomic_load(&g_loss_gen);
	r = nvmtl_vk_lost(30, g, 0, "unit", VK_TIMEOUT);
	CHECK(r == -5 && !(g_done_mask & (1ull << 30)) && atomic_load(&g_loss_gen) == g && g_state == 1, "-> %d, gen %u->%u, state %d", r, g, atomic_load(&g_loss_gen), g_state);
	atomic_store(&m_lost, 1); atomic_store(&m_banned, 1);

	printf("8. a faked loss replaces the queue with FORCE\n");
	g = atomic_load(&g_loss_gen);
	r = nvmtl_vk_lost(31, g, 1, "unit", VK_ERROR_DEVICE_LOST);
	CHECK(r == -3 && (m_flags & NVMTL_ANV_RECOVER_FORCE), "-> %d flags %u", r, m_flags);

	printf("9. the per-minute bound (NVMTL_RECOVER_MAX default 3)\n");
	reset_window(); g_quiet = 1;
	for (int i = 0; i < 3; i++) { g = atomic_load(&g_loss_gen); r = nvmtl_vk_lost(40 + i, g, 0, "unit", VK_ERROR_DEVICE_LOST); }
	CHECK(r == -3 && g_state == 1, "three recoveries in a minute pass");
	g_quiet = 0;
	g = atomic_load(&g_loss_gen); int calls = m_calls;
	r = nvmtl_vk_lost(50, g, 0, "unit", VK_ERROR_DEVICE_LOST);
	CHECK(r == -2 && g_state == -1 && m_calls == calls, "the fourth -> %d, backend down (state %d), Mesa not called", r, g_state);
	r = nvmtl_vk_lost(51, g + 1, 0, "unit", VK_ERROR_DEVICE_LOST);
	CHECK(r == -2, "once down, everything after -> %d (-2)", r);

	printf("10. Mesa fails three times: backend down\n");
	g_state = 1; reset_window(); atomic_store(&m_fail_left, 5); calls = m_calls;
	g = atomic_load(&g_loss_gen);
	r = nvmtl_vk_lost(52, g, 0, "unit", VK_ERROR_DEVICE_LOST);
	CHECK(r == -2 && g_state == -1 && m_calls - calls == 3, "-> %d, state %d, attempts %d (want -2, -1, 3)", r, g_state, m_calls - calls);
	atomic_store(&m_fail_left, 0);

	printf("11. Mesa fails once, then works\n");
	g_state = 1; reset_window(); atomic_store(&m_fail_left, 1); calls = m_calls;
	g = atomic_load(&g_loss_gen);
	r = nvmtl_vk_lost(53, g, 0, "unit", VK_ERROR_DEVICE_LOST);
	CHECK(r == -3 && g_state == 1 && m_calls - calls == 2, "-> %d, attempts %d", r, m_calls - calls);

	printf("12. the 16-per-process cap\n");
	g_quiet = 1;
	while (g_recoveries < 16) { reset_window(); g = atomic_load(&g_loss_gen); nvmtl_vk_lost(54, g, 0, "unit", VK_ERROR_DEVICE_LOST); }
	g_quiet = 0; reset_window(); g = atomic_load(&g_loss_gen);
	r = nvmtl_vk_lost(55, g, 0, "unit", VK_ERROR_DEVICE_LOST);
	CHECK(r == -2 && g_state == -1, "recovery 17 -> %d (backend down)", r);

	printf("13. NVMTL_FAKE_* parser\n");
	setenv("NVMTL_FAKE_DEVICE_LOST", "3:2", 1);
	char got[64] = ""; for (int i = 1; i <= 9; i++) if (nvmtl_fake_fire(&g_fake_wait)) { char b[8]; snprintf(b, sizeof b, "%d ", i); strcat(got, b); }
	CHECK(!strcmp(got, "3 5 7 9 "), "3:2 fires at %s(want 3 5 7 9)", got);
	setenv("NVMTL_FAKE_SUBMIT_LOST", "4", 1);
	got[0] = 0; for (int i = 1; i <= 9; i++) if (nvmtl_fake_fire(&g_fake_submit)) { char b[8]; snprintf(b, sizeof b, "%d ", i); strcat(got, b); }
	CHECK(!strcmp(got, "4 "), "4 fires at %s(want 4)", got);

	printf("%s: %d failure(s)\n", fails ? "FAILED" : "PASSED", fails);
	return fails ? 1 : 0;
}
