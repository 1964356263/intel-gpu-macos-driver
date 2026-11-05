# IntelXeFB: modes, hotplug, second monitor — Linux-sourced plan (display 14.01 / Xe2_HPD)

Source: torvalds/linux master, `drivers/gpu/drm/i915/display/*` (xe reuses it; `xe/display/xe_initial_plane.c` adopts the GOP plane like we do). Files in `scratchpad/linux/`. Offsets below are transcoder/pipe A unless said; pipe/transcoder B = +0x1000.

## 0. Facts first (verified in source)

- **Our port is DDI TC2.** AUX 0x16f410 = `_XELPDP_USBC2_AUX_CH_CTL` = AUX_CH_USBC2 (intel_dp_aux_regs.h; no xe2lpd index remap below display 20). BMG port_mask = A, TC1–TC4, no B (intel_display_device.c `xe2_hpd_display`). PORT_TC2 = enum 4 → TRANS_DDI_FUNC_CTL[30:27] should read **5**; PHY = PHY_G (`intel_port_to_phy`); TRANS_CLK_SEL value = (6+1)<<28 = **0x70000000**. All BMG ports are C20 (`intel_encoder_is_c10phy` false), none is Type-C (`intel_phy_is_tc`: dgfx → false), so no FIA/TCSS/TBT.
- **TC2 register block:** PORT_BUF_CTL1/2/3 0x16F400/404/408, M2P_MSGBUS_CTL LN0/LN1 0x16F440/444, P2M_STATUS LN0/LN1 0x16F448/44C, MSGBUS_TIMER 0x16F458, PORT_CLOCK_CTL 0x16F460, PORT_HOTPLUG_CTL 0x16F470; DDI_BUF_CTL 0x64400, DDI_CLK_VALFREQ 0x64430 (intel_cx0_phy_regs.h).
- **cdclk never changes on BMG:** `xe2hpd_cdclk_table` has one entry, 652.8 MHz (Wa_15015413771; intel_cdclk.c `intel_init_cdclk_hooks`). 2 pixels/clock (`HAS_2PPC`) → max 1305.6 Mpx/s per pipe. No cdclk work in any stage.
- **Bug in IntelXeFB.cpp:** sync polarity is TRANS_DDI_FUNC_CTL bit 16 (PHSYNC) / bit 17 (PVSYNC) (intel_display_regs.h; `intel_ddi_transcoder_func_reg_val_get`), not bits 3/4 (bits 3:1 are port width). NVRMTiming always reports negative sync now. Also PLANE_STRIDE is 12 bits (11:0), the code masks 11.

## A. Cheapest paths (no link retraining)

### A1. Scaled resolutions with a plane scaler (lowest risk)
Linux allows scaler/pipe-src changes in a fastset (intel_display.c `intel_pipe_config_compare`: `pipe_src`/`pch_pfit` checked only `if (!fastset)`; applied by `intel_pipe_fastset`). Two scalers per pipe (`num_scalers = 2`, display ≥ 11). Display 14 limits (skl_scaler.c `calculate_max_scale`, `skl_scaler_max_src_size`): scaler 0 any direction up to 3x down; scaler 1 no vertical downscale; src ≤ 4096 wide. **Use scaler 0, bound to plane 1** (`skl_program_plane_scaler`), so PIPESRC and timings stay untouched:

| Reg (pipe A, scaler 0) | Value |
|---|---|
| PS_CTRL 0x68180 | `PS_SCALER_EN`(31) \| `PS_BINDING_PLANE(PLANE_1)` = 1<<25 \| `PS_SCALER_MODE_NORMAL`(29=0) \| `PS_FILTER_MEDIUM`(24:23=0) → **0x82000000** |
| PS_VPHASE 0x68188 / PS_HPHASE 0x68194 | `PS_Y_PHASE(0) \| PS_UV_RGB_PHASE(skl_scaler_calc_phase(1, scale, false))` |
| PS_WIN_POS 0x68170 | 0 |
| PS_WIN_SZ 0x68174 | (2560<<16) \| 1440 |
| PLANE_POS 0x7018C | 0 (scaler owns output position, `icl_plane_update_noarm`) |
| PLANE_SIZE 0x70190 | ((h-1)<<16) \| (w-1) of the small mode |
| PLANE_STRIDE 0x70188 | w*4/64 (linear) |

`skl_scaler_calc_phase(1, scale, false)`: phase = -0x8000 + scale/2 (scale = src/dst in 16.16); if <0 add 0x10000 and no trip, else set trip bit 0; register = ((phase>>2) & 0xFFFE) | trip.
**Arm order** (`icl_plane_update_arm`): noarm regs (STRIDE, POS, SIZE, OFFSET), then scaler regs, then PLANE_CTL, **PLANE_SURF last** (latches). Linux enables the scaler before the plane to avoid "catastrophic underrun". Disable = `skl_detach_scaler`: PS_CTRL=0, WIN_POS=0, WIN_SZ=0, then plane regs + SURF.
The smaller surface fits inside the GOP's contiguous 14.7 MB VRAM run → **no GGTT change**. Upscaling lowers fetch bandwidth, so the GOP's DDB/WMs stay valid. PMDEMAND scalers field (0x45234[6:4]) — Linux always writes 7; read it, raise to 7 if 0 (see B). Pipe-scaler alternative (`skl_pfit_enable`: PS_CTRL = EN | `PS_BINDING_PIPE`, plus PIPESRC 0x6001C) is equivalent but also touches PIPESRC.

### A2. Refresh change at the same resolution, same link
Linux rule (`PIPE_CONF_CHECK_TIMINGS`): hdisplay/htotal/hblank/hsync are **always** compared → any horizontal change = full modeset. Vertical (vtotal/vblank/vsync) may change live only with `update_lrr` (intel_vrr.c `intel_vrr_compute_config`: sink VRR-capable and new refresh inside EDID range; `HAS_LRR` = display ≥ 12). Pixel clock may change live only with `update_m_n` (seamless DRRS, eDP panels only, `has_seamless_m_n`).

Two live paths, hardware-proven by Linux:
1. **LRR (vertical total, fixed pixel clock)** — `intel_set_transcoder_timings_lrr`: write TRANS_VBLANK 0x60010, TRANS_VSYNC 0x60014, then **TRANS_VTOTAL 0x6000C** ("latch point is the transcoder's undelayed vblank"); keep SET_CONTEXT_LATENCY 0x6007C. Refresh = pclk/(htotal·vtotal), so 180→144 Hz = vtotal × 1.25. Also refresh fixed-RR VRR regs if VRR is armed (`intel_vrr_set_fixed_rr_timings`: VMIN 0x60434, VMAX 0x60424, FLIPLINE 0x60438 = vtotal−1). Sink side: Linux sets DPCD 0x107 bit 7 `DP_MSA_TIMING_PAR_IGNORE_EN` only during link training (`intel_dp_link_training_set_mode`, comment: "GOP likely wouldn't have set this bit"). Without it a fixed-timing monitor may re-sync (brief blank, not permanent). Check sink cap DPCD 0x007 bit 6 first.
2. **M/N only (fixed timings, pixel clock scaled)** — exactly seamless DRRS. M/N are double buffered on display 9–14 (`HAS_DOUBLE_BUFFERED_M_N`; **not** on 20). `intel_set_m_n`: DATA_M1 0x60030 (TU_SIZE 30:25 = 63 | M 23:0), DATA_N1 0x60034, LINK_M1 0x60040, **LINK_N1 0x60044 last — it arms the update**. N is constant (data_n 0x8000000, link_n 0x80000, `intel_link_compute_m_n`), so scale the GOP's DATA_M/LINK_M by new_pclk/old_pclk. Risk: external sinks see MSA Mvid change; Linux never does this for non-eDP. Unsure how the Odyssey reacts.

**Must the transcoder be off to change HTOTAL?** Linux always does a full modeset for it; hardware double-buffering of HTOTAL is undocumented in the source → **assume yes**. A "transcoder-only re-time" keeping DDI/PLL/link is plausible because Linux itself passes through the state "DDI_BUF on, DP_TP_CTL Normal, TRANSCONF off" in both directions (`mtl_ddi_pre_enable_dp` trains and sets Normal before `intel_ddi_enable` turns TRANSCONF on; disable order is the reverse). Order:
1. Clear GEN8_DE_PIPE_IIR(A) 0x44408; plane off (PLANE_CTL bit31=0, rewrite PLANE_SURF); wait one FRMCOUNT tick.
2. TRANSCONF 0x70008 bit31=0; poll bit30 (STATE) clear, ≤100 ms (`intel_wait_for_pipe_off`).
3. TRANS_DDI_FUNC_CTL 0x60400: clear only bit31; keep port select/mode/width (= state written by `intel_ddi_config_transcoder_func`).
4. Write TRANS_HTOTAL/HBLANK/HSYNC/VTOTAL/VBLANK/VSYNC (0x60000–14, all "value−1"; VBLANK_START=1 on ≥13), PIPESRC, M/N (LINK_N last), WM_LINETIME 0x45270[8:0] = ceil(htotal·8000/pclk_kHz) (`skl_linetime_wm`).
5. FUNC_CTL bit31=1 (with new polarity bits 16/17); TRANS_VRR_CTL here if used (Bspec: after FUNC_CTL, before TRANSCONF, `intel_vrr_set_transcoder_timings`).
6. TRANSCONF bit31=1 (display 14: first set CHICKEN_TRANS 0x420C0 `DP_FEC_BS_JITTER_WA`, `intel_enable_transcoder`); poll bit30; PIPEDSL 0x70000 moving.
7. Plane on.
Any mode with pclk·24 ≤ link payload fits (HBR3×4 8b/10b = 20.74 Gb/s ≈ 864 MHz at 24 bpp). Keep pclk ≤ the GOP's unless WMs are recomputed. **Unverified against Bspec** — Linux never does this standalone.

### A3. VRR proper
TRANS_VRR_CTL 0x60420 for display 14 (`trans_vrr_ctl`): `VRR_CTL_FLIP_LINE_EN`(29) | guardband[15:0] (no IGN_MAX_SHIFT on 14), enable bit31 via `intel_vrr_tg_enable` after writing TRANS_PUSH 0x60A70 bit31; VMIN = vtotal−1, VMAX = pclk/(htotal·min_vfreq)−1, FLIPLINE = VMIN; each flip needs TRANS_PUSH bit30 (`intel_vrr_send_push`). Status TRANS_VRR_STATUS 0x6042C bit27 EN_LIVE. Needs MSA-ignore set and EDID range. Later stage; LRR covers fixed refresh changes.

## B. Full modeset on BMG (DP SST, 8b/10b)

`hsw_crtc_disable` → `intel_ddi_disable`/`intel_ddi_post_disable` → `intel_dpll_disable`:
1. Planes off, scalers detached (`skl_scaler_disable`).
2. `intel_ddi_post_disable_hdmi_or_sst`: TRANSCONF off + wait; `intel_vrr_transcoder_disable`; `intel_ddi_disable_transcoder_func` (FUNC_CTL2 0x60404=0; FUNC_CTL clear enable, port select, mode).
3. `intel_ddi_post_disable_dp`: DPCD 0x600=2 (D3); `intel_ddi_buf_disable`: DDI_BUF_CTL bit31=0, **wait PORT_BUF_CTL1 bit7 PHY_IDLE** (status reg is PORT_BUF_CTL1 on ≥14, `intel_ddi_buf_status_reg`, 10 ms); `mtl_ddi_disable_d2d` (PORT_BUF_CTL1 bit29=0, wait bit28 clear); DP_TP_CTL 0x60540 bit31=0; TRANS_CLK_SEL 0x46140 = 0; clear PORT_BUF_CTL1 bit11.
4. `intel_cx0pll_disable`: powerdown both lanes to P4PG (0xC; BMG port A uses P2PG 0x9, `cx0_power_control_disable_val`) via PORT_BUF_CTL2 new-state 23:20/19:16 + update bits 25/24; clear PORT_CLOCK_CTL PLL req (31/27) and refclk req (29/25); DDI_CLK_VALFREQ=0; wait acks clear; clear DDI_CLOCK_SELECT[15:12] and FORWARD_CLOCK_UNGATE bit10.

`hsw_crtc_enable`:
1. PMDEMAND pre-update (below) if PHY count/port clock/pipes change.
2. `intel_cx0pll_enable` (C20): PORT_CLOCK_CTL: DDI_CLOCK_SELECT=MAXPCLK (8), FORWARD_CLOCK_UNGATE, SSC_ENABLE_PLLB if sink downspread (DPCD 0x003 bit0; `intel_cx0pll_update_ssc`); lane reset (`intel_cx0_phy_lane_reset`: wait BUF_CTL1 bit24 SOC_PHY_READY, assert BUF_CTL2 pipe-reset 31/30, wait 29/28, refclk req/ack, powerdown P2 reset + `intel_cx0_setup_powerdown`, deassert reset, wait 29/28 clear); powerdown → P2 ready (2); MSGBUS_TIMER=0xA000; `intel_c20_pll_program`; per-TX disable (`intel_cx0_program_phy_lane`: PHY reg 0x400+(tx−1)*0x200+2 bit6); DDI_CLK_VALFREQ = link symbol clock (kHz); set PLL req bit31 (lane 0), poll ack bit30 ≤3.2 ms.
   - **C20 program**: read VDR 0xD00 bit0 (current context); write the *other* context in SRAM — Xe2_HPD addresses differ from MTL (`_XE2HPD_C20_*`): A: TX 0xCF5E, CMN 0xCE8E, MPLLA 0xCE58, MPLLB 0xCCC2; B: TX 0xCF5A, CMN 0xCE89, MPLLA 0xCE4D, MPLLB 0xCCB6 (index *subtracts*); SRAM write = msgbus writes to 0xC03,0xC02 (addr H/L), 0xC05, 0xC04 (data, committed). Then VDR 0xD02 custom width (0 for 8b/10b), 0xD00 = IS_DP(6) | rate<<1 (RBR 0, HBR1 1, HBR2 2, HBR3 3, UHBR10 8, UHBR13.5 9), finally toggle 0xD00 bit0 committed. Tables: `xe2hpd_c20_dp_tables` (RBR…UHBR13.5; **no UHBR20 on BMG**), HBR3 = `mtl_c20_dp_hbr3`.
   - **Message bus** (`__intel_cx0_write_once`/`__intel_cx0_read_once`): wait M2P bit31 clear; clear P2M status (write 1s to bits 31,15); write M2P = PENDING(31) | cmd(30:27: 1 write-uncommitted, 2 committed, 3 read) | data(23:16) | addr(11:0); committed/read: poll P2M bit31 RESPONSE_READY, check type (4 read-ack, 5 write-ack) and bit15 error; on display <30 Linux does a bus reset (M2P bit15) after every transaction. Requires DC off (we have no DMC; keep DC_STATE_EN 0x45504 = 0).
3. `mtl_ddi_pre_enable_dp`: TRANS_CLK_SEL; `intel_ddi_config_transcoder_func` (FUNC_CTL = (port+1)<<27 | DP_SST (2<<24) | BPC_8 | width(3:1) | polarity, no enable); DPCD 0x600=1; link training (below); stop training.
4. Per pipe: PIPESRC, PIPE_MISC, `hsw_configure_cpu_transcoder` (M/N, timings, TRANS_MULT=0, CHICKEN_TRANS frame-start delay, TRANSCONF value without enable), scaler, LUT, WM_LINETIME, `intel_initial_watermarks`.
5. `intel_ddi_enable`: FUNC_CTL2, FUNC_CTL | enable, VRR regs, TRANSCONF enable, then planes.

**Link training** (intel_dp_link_training.c `intel_dp_start_link_train`): `mtl_ddi_prepare_link_retrain`: DP_TP_CTL = EN | PAT1(10:8=0) | SST | enhanced-frame(18); D2D enable (BUF_CTL1 bit29, wait bit28); C20 vswing (`intel_cx0_phy_set_signal_levels`: PHY 0xD80+((lane^tx)<<4)+{0,1,2} pre/main/post, then 0xD71 override bits 0,2; table `_mtl_c20_trans_dp14`); BUF_CTL1 width 3:1 + data width 19:18 (10-bit); DDI_BUF_CTL = width | trans-select | 10BIT | bit31, wait PHY_IDLE clear (10 ms). DPCD: 0x107 (downspread/MSA-ignore), 0x108=1 (8b/10b), 0x100 link_bw (0x1E HBR3), 0x101 lanes|0x80; CR: 0x102=0x21, 0x103–0x106 swing, poll 0x202–0x207 after `drm_dp_read_clock_recovery_delay` (≤10 tries DPCD≥1.4, same-voltage 5×); EQ: TPS4 (0x102=0x07, DPCD 0x003 bit7) else TPS3 (0x23) else TPS2, DP_TP_CTL pattern 5/4/1, ≤5 tries; stop: DP_TP_CTL Normal (3), 0x102=0.

**Power wells** (intel_display_power_map.c `xelpdp_power_wells`): PW_1, PW_2, PW_A–D, AUX_A/B/TC1–4; no DDI-IO wells on 14. Driver request reg HSW_PWR_WELL_CTL2 0x45404 (req = 2<<(idx·2), state = 1<<(idx·2)): PW_2 idx1, PW_A 5, PW_B 6, PW_C 7, PW_D 8. BIOS reg 0x45400 may hold the GOP's requests.

**PMDEMAND** (intel_pmdemand.c, `HAS_PMDEMAND` ≥14): 0x45230 = qclk_bw 31:16 | voltage 14:12 | qclk_idx 11:8 | pipes 7:6 | dbufs 5:4 | phys 2:0; 0x45234 = REQ 31 | cdclk MHz 30:20 | ddiclk MHz 18:8 | scalers 6:4 | plls 2:0 (= phys+1). Wait 0x45234 bit31 and DCPR_STATUS_1 0x46440 bit26 clear, write max(old,new) before, new after; set bit31, poll clear ≤10 ms.

**What the GOP already did (keep):** PW_1/PW_2/PW_A, cdclk, DBUF slices and MBUS mode, initial PMDEMAND, TC2 PHY (PLL locked, lanes, vswing from training), trained link, TRANS_CLK_SEL, FUNC_CTL, timings, M/N, plane 1 DDB/WM, PIPE_MISC. Probably not: HPD enables/inversion, PW_B–D, other PHYs, DMC.

## C. Hotplug on BMG
BMG is `PCH_MTL` (intel_pch.c) and TC ports are non-TC, so `dig_port->connected = lpt_digital_port_connected` → **SDEISR 0xC4000 live bit, poll it**: TC1–TC4 = bits 24–27 (`SDE_TC_HOTPLUG_ICP`), DDI A = bit 16. Our monitor = **bit 25**. Setup as Linux (`mtp_hpd_irq_setup`, called from `xelpdp_hpd_irq_setup`): SHPD_FILTER_CNT 0xC4038 = 0xF8 (250 µs); SOUTH_CHICKEN1 0xC2000 |= INVERT bits 15–17, 23–28 (`mtp_hpd_invert` — without it the live level may read inverted; read first); SHOTPLUG_CTL_TC 0xC4034 |= 8<<(n·4) per TC port (enable), SHOTPLUG_CTL_DDI 0xC4030 bit3 for A. Sticky events: SHOTPLUG_CTL_TC nibble bits 1 (long) / 0 (short), cleared by writing the value back (`icp_irq_handler`); SDEIIR 0xC4008 sticky, W1C. North PICA (PICAINTERRUPT_ISR 0x16FE50, PORT_HOTPLUG_CTL 0x16F270+n·0x200) carries DP-alt/TBT HPD — irrelevant on dGPU, but harmless to watch. Poll every 100–250 ms in a thread_call; on change debounce, then DPCD 0x200 (SINK_COUNT[5:0]) and EDID, then call the kIOFBConnectInterruptType proc. Short pulses (sink IRQ): read DPCD 0x201 and 0x202–0x205; link lost → retrain (stage 5).

## D. Second monitor
- **PLL:** yes, dedicated per PHY. `mtl_pll_mgr` maps each port 1:1 (`mtl_port_to_pll_id`: A→DPLL0, TC n→"TC PLL n"); the PLL is the PHY's own MPLLA/B, never shared. cdclk unchanged.
- **Power:** PW_B (CTL2 bits 13/12).
- **DBUF/MBUS:** display 14 uses `adlp_allowed_dbufs` (skl_watermark.c `skl_compute_dbuf_slices`; DBUF 4096 blocks, 4×1024). One pipe = all 4 slices with **MBUS joined** (MBUS_CTL 0x4438C: JOIN 31, hashing 1x4 bit30, pipe select 28:26). Pipes A+B = A: S1+S2, B: S3+S4, **unjoined** (2x2). PLANE_BUF_CFG is relative to the MBUS bank (`mbus_ddb_offset`), so B's range is also 0–2047. Order (`intel_dbuf_mbus_post_ddb_update`): shrink A's DDB (PLANE_BUF_CFG 0x7027C, CUR_BUF_CFG 0x7017C) to ≤2047 and its WMs first, then PIPE_MBUS_DBOX_CTL A (A credit 12→8, 0x7003C, `pipe_mbus_dbox_ctl`), then MBUS_CTL unjoin, wait a vblank; power slices via DBUF_CTL_S1–S4 (0x45008, 0x44FE8, 0x44300, 0x44304; req 31/state 30). Read MBUS_CTL first: the GOP may not have joined.
- **WMs for B plane 1:** PLANE_WM_1_B_0 0x71240 (EN 31, lines 26:14, blocks 12:0), WM_TRANS 0x71268, BUF_CFG 0x7127C. Level 0 alone is enough to scan out; higher levels only allow memory power saving. Simplest: copy pipe A's GOP values for the same mode; formula `skl_compute_plane_wm` with latency from 0x45780 [12:0].
- **PMDEMAND:** pipes 2, phys 2, plls 3, ddiclk = max.
- **Surface:** a new contiguous VRAM run + **GGTT PTEs** (coordinate with the B580 accel kext's GGTT use).
- Transcoder B, TRANS_CLK_SEL B 0x46144, full stage-5 enable on the second port.

## E. Staged plan (risk ascending)

Verification toolkit (all remote): FRMCOUNT 0x70040 advancing; TRANSCONF bit30; PIPEDSL moving; GEN8_DE_PIPE_IIR 0x44408 bit31 underrun (clear before, check after); pipe CRC: PIPE_CRC_CTL 0x60050 = 0x80000000|(4<<28) (DMUX = pipe output), result PIPE_CRC_RES 0x60064, done flag IIR bit28 — record the CRC of a known solid colour now and compare after changes; DPCD 0x202/0x203 = 0x77 (x4), 0x204 bit0 align, 0x205 bit0 in-sync, 0x200 sink count; DP_TP_STATUS 0x60544; PORT_CLOCK_CTL bit30 PLL ack; PORT_BUF_CTL1 bit7 = 0. **Wrap every write stage in snapshot + auto-revert:** save all touched regs, apply, check the list within ~2 s, restore on failure; plus a sysctl "confirm within 15 s or revert".

| # | Stage | ~LOC | Dark risk | Verify |
|---|---|---|---|---|
| 0 | Read-only dump sysctl: all regs above, DPCD 0x000–0x00F/0x100–0x108/0x200–0x207, MBUS/DBUF/PMDEMAND/power wells, **C20 SRAM context via msgbus reads** (proves msgbus vs `mtl_c20_dp_hbr3`); fix polarity bug | 300 | none (msgbus reads only) | values plausible, FUNC_CTL port=5 |
| 1 | Hotplug poll (SDEISR bit 25 etc.) + connect interrupt + EDID re-read | 200 | none | unplug/replug logs, SDEISR toggles |
| 2 | Scaled modes via plane scaler 0 (A1), mode list from EDID ≤ 2560×1440 | 350 | **low**: wrong PS regs = black/garbage, revert restores | underrun clear, CRC changes as expected, FRMCOUNT |
| 3 | Refresh via LRR (A2.1) inside EDID range; optional DPCD 0x107 bit7 | 150 | low-medium: sink may resync | 0x205 bit0, FRMCOUNT rate, VTOTAL readback |
| 4 | Transcoder-only re-time on the same link (A2 order) for other timings | 300 | **medium: panel may go dark** if sink drops; link/PLL untouched, revert = old timings | 0x202–0x205, TRANSCONF bit30, CRC |
| 5 | Full modeset: first *retrain at the same HBR3×4* (exercises DP_TP_CTL/DDI_BUF/training, PLL kept), then PLL reprogram/other rates | 1200–1500 | **high: dark until a successful retrain**; have revert = full re-enable at GOP params | 0x202–0x204, PLL ack, PHY_IDLE, CRC |
| 6 | Second pipe on another port: PW_B, PMDEMAND, MBUS unjoin, DDB/WM, GGTT surface, stage-5 enable | 800 + stage 5 | high for the new panel; **MBUS unjoin can underrun pipe A** | pipe A IIR underrun, both FRMCOUNTs |

## Unsure / differs by version
- HTOTAL double buffering and the transcoder-only re-time (A2 step list) are inferred, not in Linux.
- How the Odyssey handles live M/N or VTOTAL changes without MSA-ignore.
- Keeping the PLL across a same-rate retrain (Linux always disables it).
- Whether the GOP set SOUTH_CHICKEN1 inversion / HPD enables (read them).
- 13 vs 14 vs 20: DG2 (13) uses SNPS PHYs and `dg2_allowed_dbufs`; 14 C20 with Xe2_HPD SRAM offsets and D2D in PORT_BUF_CTL1; 20+ moves D2D to DDI_BUF_CTL, remaps AUX/PORT indices (`__xe2lpd_*_idx`), loses double-buffered M/N; 30+ always uses the VRR timing generator. PMDEMAND exists from 14.
