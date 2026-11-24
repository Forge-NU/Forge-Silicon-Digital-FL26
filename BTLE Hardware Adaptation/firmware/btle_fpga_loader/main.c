// btle_fpga_loader -- pico2-ice RP2350 firmware for the btle_mvp iCE40 design.
//
// On every boot:
//   1. start the FPGA's 12 MHz clock on GPIO21 (ICE_35_G0) and hold the FPGA in reset (GPIO31)
//   2. FLASH path: exit continuous-read mode, reset and wake the config flash, and if it answers
//      a JEDEC ID read (bit-banged SPI: MOSI
//      GPIO7 -> flash DI, MISO GPIO4 <- flash DO, SCK GPIO6, CS GPIO5, per the pico2-ice Rev1/2
//      netlist), make the flash match the embedded bitstream (rewrite only if different), then
//      release CRESET so the FPGA boots from it.  This persists without the RP2350.
//   3. CRAM path: if the flash does not answer, or the FPGA does not configure from it, load
//      the bitstream straight into the FPGA's configuration RAM over SPI with pico-ice-sdk's
//      ice_cram_* (volatile; this firmware repeats it on every power-up).
//   4. RGB LED: green = FPGA configured, red = failed.  Status every 2 s on USB serial.
//
// The FPGA design configures the AT86RF215 itself; the RP2350 only provides clock and bitstream.

#include <stdio.h>
#include <string.h>

#include "boards.h"
#include "hardware/adc.h"
#include "hardware/gpio.h"
#include "hardware/spi.h"
#include "ice_cram.h"
#include "ice_fpga.h"
#include "pico/stdlib.h"

extern const uint8_t bitstream_start[];
extern const uint8_t bitstream_end[];

#define FPGA_CLK_HZ   12000000u   // must match CFG_CLK_LOCAL_HZ in btle_mvp_config.vh
#define PIN_LED_G     0           // RGB LED, common anode: active low
#define PIN_LED_R     1
#define PIN_LED_B     9
#define PIN_CRESET    31
#define PIN_CDONE     40          // also ADC0; high level clamped to ~2 V by an LED
#define CDONE_ADC     0
#define CDONE_HIGH_V  1.2f

#define PIN_F_DO      4           // flash DO  = iCE40 SPI_SI (pin 17), 10k pull-down
#define PIN_F_CS      5           // flash CS# = iCE40 SPI_SS (pin 16), 10k pull-up
#define PIN_F_SCK     6           // via 27 ohm, 10k pull-down
#define PIN_F_DI      7           // flash DI  = iCE40 SPI_SO (pin 14)

#define PAGE   256u
#define SECTOR 4096u

static void led(int r, int g, int b) {
    gpio_put(PIN_LED_R, !r);
    gpio_put(PIN_LED_G, !g);
    gpio_put(PIN_LED_B, !b);
}

static float cdone_volts(void) {
    adc_select_input(CDONE_ADC);
    return adc_read() * 3.3f / 4096.0f;
}

static bool wait_cdone(int ms) {
    for (int t = 0; t < ms; t++) {
        if (cdone_volts() > CDONE_HIGH_V) return true;
        sleep_ms(1);
    }
    return cdone_volts() > CDONE_HIGH_V;
}

// ---------------- bit-banged SPI master for the config flash (mode 0, MSB first, ~1 MHz)
static inline void dly(void) { for (volatile int i = 0; i < 40; i++) { } }

static uint8_t xfer(uint8_t out) {
    uint8_t in = 0;
    for (int b = 7; b >= 0; b--) {
        gpio_put(PIN_F_DI, (out >> b) & 1);
        dly();
        gpio_put(PIN_F_SCK, 1);
        dly();
        in = (uint8_t)((in << 1) | gpio_get(PIN_F_DO));
        gpio_put(PIN_F_SCK, 0);
    }
    return in;
}
static void cs(bool low) { dly(); gpio_put(PIN_F_CS, !low); dly(); }
static void cmd1(uint8_t c) { cs(true); xfer(c); cs(false); }
static uint8_t read_sr(void) { cs(true); xfer(0x05); uint8_t s = xfer(0); cs(false); return s; }
static void addr24(uint8_t c, uint32_t a) {
    xfer(c); xfer((uint8_t)(a >> 16)); xfer((uint8_t)(a >> 8)); xfer((uint8_t)a);
}
static bool wait_ready(uint32_t timeout_ms) {
    absolute_time_t end = make_timeout_time_ms(timeout_ms);
    while (!time_reached(end)) if (!(read_sr() & 0x01)) return true;
    return false;
}
static void flash_read(uint32_t a, uint8_t *buf, size_t n) {
    cs(true); addr24(0x03, a);
    for (size_t i = 0; i < n; i++) buf[i] = xfer(0);
    cs(false);
}

static void bus_take(void) {
    gpio_init(PIN_F_CS);  gpio_put(PIN_F_CS, 1);  gpio_set_dir(PIN_F_CS, GPIO_OUT);
    gpio_init(PIN_F_SCK); gpio_put(PIN_F_SCK, 0); gpio_set_dir(PIN_F_SCK, GPIO_OUT);
    gpio_init(PIN_F_DI);  gpio_put(PIN_F_DI, 0);  gpio_set_dir(PIN_F_DI, GPIO_OUT);
    gpio_init(PIN_F_DO);  gpio_set_dir(PIN_F_DO, GPIO_IN); gpio_disable_pulls(PIN_F_DO);
}
static void bus_release(void) {
    const uint pins[] = {PIN_F_DO, PIN_F_CS, PIN_F_SCK, PIN_F_DI};
    for (unsigned i = 0; i < 4; i++) {
        gpio_init(pins[i]); gpio_set_dir(pins[i], GPIO_IN); gpio_disable_pulls(pins[i]);
    }
}

// ---------------- status
static uint8_t jedec[3];
static int fl = -100;            // flash: 0 up to date, 1 written+verified, <0 failed/absent
static size_t first_diff = 0;
static const char *method = "none";

static void sync_flash(size_t len) {
    static uint8_t page[PAGE];
    bus_take();
    // Exit continuous-read mode first: 16 clocks with DI high under CS (W25Q "mode reset").
    // Seen on this board: the flash ignored everything (JEDEC 000000) until this happened.
    cs(true); xfer(0xFF); xfer(0xFF); cs(false);
    cmd1(0x66); cmd1(0x99); sleep_us(50);             // software reset
    cmd1(0xAB); sleep_us(50);                         // release power-down
    cs(true); xfer(0x9F); jedec[0] = xfer(0); jedec[1] = xfer(0); jedec[2] = xfer(0); cs(false);
    if ((jedec[0] == 0x00 && jedec[1] == 0x00) || (jedec[0] == 0xFF && jedec[1] == 0xFF)) {
        fl = -1; bus_release(); return;               // flash does not answer
    }
    first_diff = len;
    for (size_t a = 0; a < len; a += PAGE) {
        size_t n = (len - a < PAGE) ? len - a : PAGE;
        flash_read(a, page, n);
        if (memcmp(page, bitstream_start + a, n) != 0) { first_diff = a; break; }
    }
    if (first_diff == len) { fl = 0; bus_release(); return; }

    led(0, 0, 1);
    for (size_t a = 0; a < len; a += SECTOR) {
        cmd1(0x06); cs(true); addr24(0x20, a); cs(false);
        if (!wait_ready(1000)) { fl = -3; bus_release(); return; }
    }
    for (size_t a = 0; a < len; a += PAGE) {
        size_t n = (len - a < PAGE) ? len - a : PAGE;
        cmd1(0x06);
        cs(true); addr24(0x02, a);
        for (size_t i = 0; i < n; i++) xfer(bitstream_start[a + i]);
        cs(false);
        if (!wait_ready(100)) { fl = -4; bus_release(); return; }
    }
    for (size_t a = 0; a < len; a += PAGE) {
        size_t n = (len - a < PAGE) ? len - a : PAGE;
        flash_read(a, page, n);
        if (memcmp(page, bitstream_start + a, n) != 0) { first_diff = a; fl = -6; bus_release(); return; }
    }
    fl = 1;
    bus_release();
}

// ---------------- debug SPI terminal (RP2350 bit-banged master -> FPGA spi_dbg_slave)
// GPIO26 SCK -> ICE21, GPIO20 MOSI -> ICE27, GPIO24 MISO <- ICE26, GPIO22 CS -> ICE20;
// ~250 kHz, mode 0 (the FPGA slave oversamples at 12 MHz, so keep SCK under 2 MHz).
// Frame: {W, A[6:0]}, then data.  The FPGA answers 0xA5 during the command byte.
// GPIO23/25/27/30 carry the FPGA's radio SPI (ICE19/23/18/25) and must stay undriven here.
#define PIN_D_MISO 24
#define PIN_D_CS   22
#define PIN_D_SCK  26
#define PIN_D_MOSI 20

static void dbg_spi_init(void) {
    const uint radio_nets[] = {23, 25, 27, 30};
    for (unsigned i = 0; i < 4; i++) {
        gpio_init(radio_nets[i]); gpio_set_dir(radio_nets[i], GPIO_IN); gpio_disable_pulls(radio_nets[i]);
    }
    gpio_init(PIN_D_CS);   gpio_put(PIN_D_CS, 1);   gpio_set_dir(PIN_D_CS, GPIO_OUT);
    gpio_init(PIN_D_SCK);  gpio_put(PIN_D_SCK, 0);  gpio_set_dir(PIN_D_SCK, GPIO_OUT);
    gpio_init(PIN_D_MOSI); gpio_put(PIN_D_MOSI, 0); gpio_set_dir(PIN_D_MOSI, GPIO_OUT);
    gpio_init(PIN_D_MISO); gpio_set_dir(PIN_D_MISO, GPIO_IN); gpio_disable_pulls(PIN_D_MISO);
}

static uint8_t dbg_xfer(uint8_t out) {
    uint8_t in = 0;
    for (int b = 7; b >= 0; b--) {
        gpio_put(PIN_D_MOSI, (out >> b) & 1);
        sleep_us(2);
        gpio_put(PIN_D_SCK, 1);
        sleep_us(2);
        in = (uint8_t)((in << 1) | gpio_get(PIN_D_MISO));
        gpio_put(PIN_D_SCK, 0);
    }
    return in;
}

// read n FPGA registers from a; returns the link marker (0xA5 when the FPGA answers)
static uint8_t fpga_rd(uint8_t a, uint8_t *buf, size_t n) {
    gpio_put(PIN_D_CS, 0); sleep_us(5);
    uint8_t mk = dbg_xfer(a & 0x7F);
    for (size_t i = 0; i < n; i++) buf[i] = dbg_xfer(0);
    sleep_us(5); gpio_put(PIN_D_CS, 1); sleep_us(10);
    return mk;
}

static void fpga_wr(uint8_t a, uint8_t v) {
    gpio_put(PIN_D_CS, 0); sleep_us(5);
    dbg_xfer((uint8_t)(0x80 | (a & 0x7F)));
    dbg_xfer(v);
    sleep_us(5); gpio_put(PIN_D_CS, 1); sleep_us(10);
}

// radio register read through the FPGA; returns -1 on timeout
static int radio_rd(uint16_t addr) {
    uint8_t s;
    fpga_wr(0x10, (addr >> 8) & 0x3F);
    fpga_wr(0x11, addr & 0xFF);
    fpga_wr(0x12, 1);
    absolute_time_t end = make_timeout_time_ms(300);   // served within one TX period (100 ms)
    do {
        fpga_rd(0x12, &s, 1);
        if (!(s & 0x02)) { fpga_rd(0x13, &s, 1); return s; }
        sleep_ms(1);
    } while (!time_reached(end));
    return -1;
}

// radio register write through the FPGA (served while the sequencer is idle); 0 ok, -1 timeout
static int radio_wr(uint16_t addr, uint8_t val) {
    uint8_t s;
    fpga_wr(0x10, (addr >> 8) & 0x3F);
    fpga_wr(0x11, addr & 0xFF);
    fpga_wr(0x1E, val);
    absolute_time_t end = make_timeout_time_ms(300);
    do {
        fpga_rd(0x12, &s, 1);
        if (!(s & 0x02)) return 0;
        sleep_ms(1);
    } while (!time_reached(end));
    return -1;
}

static const char *seq_state_name(uint8_t s) {
    static const char *n[] = {"RST_LOW", "BOOT", "FETCH", "SPI_START", "SPI_WAIT", "EVAL", "GAP",
                              "WAIT_PERIOD (listening)", "WAIT_CLKS", "WAIT_DATA", "WAIT_DONE",
                              "FAULT", "DBG_START", "DBG_WAIT"};
    return s < 14 ? n[s] : "?";
}

static void print_rd(const char *name, uint16_t a) {
    int v = radio_rd(a);
    if (v < 0) printf("  %-10s 0x%04X = (timeout: sequencer busy or not running)\n", name, a);
    else       printf("  %-10s 0x%04X = 0x%02X\n", name, a, v);
}

static void cmd_stat(size_t len) {
    uint8_t r[11];
    printf("loader: flash JEDEC %02X%02X%02X, flash %s (code %d); FPGA %s via %s; CDONE %.2f V; "
           "bitstream %u B\n",
           jedec[0], jedec[1], jedec[2],
           fl == 1 ? "written+verified" : fl == 0 ? "up to date" : fl == -1 ? "not answering" : "FAILED",
           fl, cdone_volts() > CDONE_HIGH_V ? "CONFIGURED" : "NOT configured", method,
           cdone_volts(), (unsigned)len);
    uint8_t mk = fpga_rd(0x00, r, 11);
    printf("FPGA debug SPI: marker 0x%02X (%s), magic 0x%02X (%s), version %u\n", mk,
           mk == 0xA5 ? "ok" : "BAD", r[0], r[0] == 0xB7 ? "ok" : "BAD", r[1]);
    if (mk != 0xA5) { printf("  no link to the FPGA debug port; is the FPGA configured?\n"); return; }
    printf("  status 0x%02X: ready=%d fault=%d listening=%d stream=%d lvds_rx_lock=%d irq=%d\n",
           r[2], r[2] & 1, (r[2] >> 1) & 1, (r[2] >> 2) & 1, (r[2] >> 3) & 1, (r[2] >> 4) & 1,
           (r[2] >> 5) & 1);
    printf("  radio PN at bring-up 0x%02X (%s), last SPI read 0x%02X, seq pc %u, state %s\n",
           r[3], r[3] == 0x34 ? "AT86RF215" : r[3] == 0x35 ? "AT86RF215IQ" : "NOT a 2.4 GHz AT86RF215",
           r[4], r[5], seq_state_name(r[6]));
    printf("  counters: faults %u, TX packets %u, RX good %u, RX decodes %u\n", r[7], r[8], r[9], r[10]);
    printf("radio registers read by the FPGA over its SPI:\n");
    print_rd("RF_PN", 0x000D);
    print_rd("RF_VN", 0x000E);
    print_rd("IQIFC0", 0x000A);
    print_rd("IQIFC1", 0x000B);
    print_rd("IQIFC2", 0x000C);
    print_rd("RF24_STATE", 0x0202);
}

// Watch the radio SPI nets directly (the RP2350 shares them with the FPGA, inputs only):
// count edges for ~500 ms, and test whether MISO is driven or just held up by the FPGA's pull-up.
static void cmd_probe(void) {
    const uint pin[4] = {27, 25, 23, 30};
    const char *nm[4] = {"SCK  (ICE18/GPIO27)", "MOSI (ICE23/GPIO25)", "MISO (ICE19/GPIO23)",
                         "SELN (ICE25/GPIO30)"};
    uint32_t edges[4] = {0}, highs[4] = {0}, n = 0;
    int last[4];
    for (int i = 0; i < 4; i++) last[i] = gpio_get(pin[i]);
    absolute_time_t end = make_timeout_time_ms(500);
    while (!time_reached(end)) {
        uint32_t all = gpio_get_all();
        for (int i = 0; i < 4; i++) {
            int v = (all >> pin[i]) & 1;
            if (v != last[i]) { edges[i]++; last[i] = v; }
            highs[i] += v;
        }
        n++;
    }
    printf("radio SPI nets over 500 ms (%lu samples):\n", (unsigned long)n);
    for (int i = 0; i < 4; i++)
        printf("  %s  edges %6lu  high %3lu%%\n", nm[i], (unsigned long)edges[i],
               (unsigned long)(100ull * highs[i] / n));
    // MISO drive test: RP pull-down against the FPGA's weak pull-up while SELN is high
    gpio_pull_down(23); sleep_us(200);
    int md = 0; for (int k = 0; k < 1000; k++) md += gpio_get(23);
    gpio_disable_pulls(23);
    printf("  MISO with RP pull-down: high %d/1000 (near 0 = nothing drives it, only weak pull-ups)\n", md);
    printf("  expect: SCK/MOSI/SELN edges > 0 (FPGA is talking); MISO edges > 0 if the radio answers\n");
}

// Logic-analyser capture of one FPGA->radio transfer (the read-through of radio register a):
// tight-loop sampling of the radio SPI nets, then decode MOSI/MISO on rising SCK edges.
#define CAP_N 12000
static uint32_t cap_buf[CAP_N];
static void cmd_cap(uint16_t a) {
    const uint P_SCK = 27, P_MOSI = 25, P_MISO = 23, P_CS = 30;
    fpga_wr(0x10, (a >> 8) & 0x3F);
    fpga_wr(0x11, a & 0xFF);
    absolute_time_t end = make_timeout_time_ms(500);
    while (!gpio_get(P_CS) && !time_reached(end)) { }
    fpga_wr(0x12, 1);
    uint32_t t0 = time_us_32();
    while (gpio_get(P_CS)) { if (time_us_32() - t0 > 300000) { printf("no CS edge (sequencer busy?)\n"); return; } }
    uint32_t c0 = time_us_32();
    for (int i = 0; i < CAP_N; i++) cap_buf[i] = sio_hw->gpio_in;
    uint32_t dt = time_us_32() - c0;

    uint32_t mo = 0, mi = 0; int bits = 0, cs_end = -1;
    for (int i = 1; i < CAP_N; i++) {
        if ((cap_buf[i] >> P_CS) & 1) { cs_end = i; break; }
        int s0 = (cap_buf[i - 1] >> P_SCK) & 1, s1 = (cap_buf[i] >> P_SCK) & 1;
        if (!s0 && s1 && bits < 32) {
            mo = (mo << 1) | ((cap_buf[i] >> P_MOSI) & 1);
            mi = (mi << 1) | ((cap_buf[i] >> P_MISO) & 1);
            bits++;
        }
    }
    printf("capture: %d samples in %lu us (%.1f MS/s), CS low for %d samples, %d rising SCK edges\n",
           CAP_N, (unsigned long)dt, CAP_N / (float)dt, cs_end, bits);
    printf("  MOSI (to radio):   %06lX -> mode %lu, addr 0x%04lX, data %02lX\n", (unsigned long)(mo & 0xFFFFFF),
           (unsigned long)((mo >> 22) & 3), (unsigned long)((mo >> 8) & 0x3FFF), (unsigned long)(mo & 0xFF));
    printf("  MISO (from radio): %06lX -> data byte %02lX\n", (unsigned long)(mi & 0xFFFFFF),
           (unsigned long)(mi & 0xFF));
    sleep_ms(2);
    uint8_t s; fpga_rd(0x13, &s, 1);
    printf("  FPGA's own result: 0x%02X\n", s);

    // raw transitions while CS is low (columns CS SCK MOSI MISO)
    float us_per = dt / (float)CAP_N;
    uint32_t mask = (1u << P_CS) | (1u << P_SCK) | (1u << P_MOSI) | (1u << P_MISO);
    uint32_t prev = 0xFFFFFFFF;
    for (int i = 0; i < CAP_N && (cs_end < 0 || i <= cs_end + 40); i++) {
        uint32_t v = cap_buf[i] & mask;
        if (v != prev) {
            printf("    %7.2f us  %lu %lu %lu %lu\n", i * us_per, (unsigned long)((v >> P_CS) & 1),
                   (unsigned long)((v >> P_SCK) & 1), (unsigned long)((v >> P_MOSI) & 1),
                   (unsigned long)((v >> P_MISO) & 1));
            prev = v;
        }
    }
}

// Raw waveform: trigger on the next CS falling edge (any frame), print every transition of
// CS/SCK/MOSI/MISO with its time in microseconds.
static void cmd_scope(void) {
    const uint P_SCK = 27, P_MOSI = 25, P_MISO = 23, P_CS = 30;
    uint32_t t0 = time_us_32();
    while (!gpio_get(P_CS)) { if (time_us_32() - t0 > 500000) { printf("CS stuck low\n"); return; } }
    while (gpio_get(P_CS))  { if (time_us_32() - t0 > 1000000) { printf("no CS falling edge in 1 s\n"); return; } }
    uint32_t c0 = time_us_32();
    for (int i = 0; i < CAP_N; i++) cap_buf[i] = sio_hw->gpio_in;
    float us_per = (time_us_32() - c0) / (float)CAP_N;
    printf("scope: %.1f ns/sample, columns CS SCK MOSI MISO\n", us_per * 1000.0f);
    uint32_t mask = (1u << P_CS) | (1u << P_SCK) | (1u << P_MOSI) | (1u << P_MISO);
    uint32_t prev = cap_buf[0] & mask;
    int shown = 0;
    printf("  %8.2f us  %lu %lu %lu %lu\n", 0.0, (unsigned long)((prev >> P_CS) & 1), (unsigned long)((prev >> P_SCK) & 1),
           (unsigned long)((prev >> P_MOSI) & 1), (unsigned long)((prev >> P_MISO) & 1));
    for (int i = 1; i < CAP_N && shown < 130; i++) {
        uint32_t v = cap_buf[i] & mask;
        if (v != prev) {
            printf("  %8.2f us  %lu %lu %lu %lu\n", i * us_per, (unsigned long)((v >> P_CS) & 1),
                   (unsigned long)((v >> P_SCK) & 1), (unsigned long)((v >> P_MOSI) & 1),
                   (unsigned long)((v >> P_MISO) & 1));
            prev = v;
            shown++;
        }
    }
}

static void help(void) {
    printf("commands:\n"
           "  stat              FPGA status + key radio registers read through the FPGA\n"
           "  rd <addr>         read one radio register through the FPGA (hex, e.g. rd 0x0202)\n"
           "  fpga <reg> [n]    raw FPGA debug registers (0x00..0x13)\n"
           "  help\n");
}

static void terminal(size_t len) {
    char line[64];
    size_t n = 0;
    sleep_ms(1500);                                   // let the USB host open the port
    printf("\nbtle_fpga_loader SPI terminal. Type help.\n");
    cmd_stat(len);
    printf("> ");
    while (true) {
        int c = getchar_timeout_us(100000);
        if (c == PICO_ERROR_TIMEOUT) continue;
        if (c == '\r' || c == '\n') {
            printf("\n");
            line[n] = 0;
            char cmd[16] = {0}; unsigned a = 0, b = 1;
            int k = sscanf(line, "%15s %x %u", cmd, &a, &b);
            if (k >= 1) {
                if (!strcmp(cmd, "stat")) cmd_stat(len);
                else if (!strcmp(cmd, "probe")) cmd_probe();
                else if (!strcmp(cmd, "scope")) cmd_scope();
                else if (!strcmp(cmd, "wr") && k >= 2) {
                    unsigned r = 0, v = 0;
                    if (sscanf(line, "%*s %x %x", &r, &v) == 2) {
                        int e = radio_wr((uint16_t)r, (uint8_t)v);
                        if (e) printf("radio write timeout\n");
                        else   printf("radio[0x%04X] <= 0x%02X\n", r, v);
                    } else printf("usage: wr <addr hex> <val hex>\n");
                }
                else if (!strcmp(cmd, "fw") && k >= 2) {
                    unsigned r = 0, v = 0;
                    if (sscanf(line, "%*s %x %x", &r, &v) == 2) { fpga_wr((uint8_t)r, (uint8_t)v); printf("fpga[0x%02X] <= 0x%02X\n", r, v); }
                    else printf("usage: fw <reg hex> <val hex>\n");
                }
                else if (!strcmp(cmd, "cap") && k >= 2) cmd_cap((uint16_t)a);
                else if (!strcmp(cmd, "rd") && k >= 2) {
                    int v = radio_rd((uint16_t)a);
                    if (v < 0) printf("timeout\n"); else printf("radio[0x%04X] = 0x%02X\n", a, v);
                } else if (!strcmp(cmd, "fpga") && k >= 2) {
                    uint8_t buf[16];
                    if (b < 1) b = 1;
                    if (b > 16) b = 16;
                    uint8_t mk = fpga_rd((uint8_t)a, buf, b);
                    printf("marker 0x%02X:", mk);
                    for (unsigned i = 0; i < b; i++) printf(" %02X", buf[i]);
                    printf("\n");
                } else help();
            }
            n = 0;
            printf("> ");
        } else if ((c == 8 || c == 127) && n > 0) {
            n--; printf("\b \b");
        } else if (c >= 32 && n < sizeof line - 1) {
            line[n++] = (char)c; putchar(c);
        }
    }
}

int main(void) {
    stdio_init_all();

    gpio_init(PIN_LED_R); gpio_set_dir(PIN_LED_R, GPIO_OUT);
    gpio_init(PIN_LED_G); gpio_set_dir(PIN_LED_G, GPIO_OUT);
    gpio_init(PIN_LED_B); gpio_set_dir(PIN_LED_B, GPIO_OUT);
    led(0, 0, 0);
    adc_init();
    adc_gpio_init(PIN_CDONE);
    dbg_spi_init();                                   // release the radio-SPI nets at once

    ice_fpga_init(FPGA_DATA, FPGA_CLK_HZ);            // clock on GPIO21
    ice_fpga_stop(FPGA_DATA);                         // CRESET low (output)
    sleep_ms(2);

    const size_t len = (size_t)(bitstream_end - bitstream_start);

    // 1. flash path
    sync_flash(len);
    bool done = false;
    if (fl >= 0) {
        ice_fpga_start(FPGA_DATA);
        done = wait_cdone(1000);
        if (done) method = (fl == 1) ? "flash (rewritten)" : "flash (already up to date)";
    }

    // 2. CRAM path: load the FPGA directly (ice_cram_open needs CRESET as an output)
    if (!done) {
        led(0, 0, 1);
        ice_fpga_stop(FPGA_DATA);
        sleep_ms(1);
        bool opened = ice_cram_open(FPGA_DATA);
        if (opened) {
            ice_cram_write(bitstream_start, len);
            ice_cram_close();
            bus_release();
            done = wait_cdone(200);
            method = done ? "CRAM (direct load, repeated every boot)" : "CRAM load failed";
        } else {
            method = "ice_cram_open failed";
        }
    }
    led(!done, done, 0);

    dbg_spi_init();
    terminal(len);
}
